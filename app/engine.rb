# engine.rb
# encoding: UTF-8
#
# 레이드 전투 엔진. 전투봇(battle/)의 규칙 코드를 그대로 불러와 쓴다.
# - 명중/회피/크리티컬/피해 계산, 정산 순서, 스킬, 쿨타임, 기숙사 패시브: battle/*.rb 그대로
# - 라운드 진행 함수(준비 → 보스 행동 → 행동 입력 → 정산): battle/main.rb 의 함수 본문을
#   실행 시점에 그대로 읽어 와 사용 (복사본을 따로 두지 않아 규칙이 어긋나지 않음)
# - 마스토돈 게시 → 웹 전투 기록으로, 구글 시트 → data/raid.json 으로 대체

require 'set'
require 'json'
require 'securerandom'
require 'monitor'

APP_DIR    = __dir__
RAID_DATA_DIR = File.expand_path(ENV['RAID_DATA_DIR'].to_s.strip.empty? ? File.join(__dir__, 'data') : ENV['RAID_DATA_DIR'])
BATTLE_DIR = File.expand_path('../battle', __dir__)
$LOAD_PATH.unshift(File.join(APP_DIR, 'stubs'))

ENV['WEB_ENABLED'] = 'true'

require File.join(BATTLE_DIR, 'sheet_manager')
require_relative 'local_sheet'
%w[battle_util battle_grid battle_skills battle_calculator battle_state
   battle_boss_patterns battle_round battle_session talk_lines web_state].each do |f|
  require File.join(BATTLE_DIR, f)
end
require_relative 'skill_catalog'

ACTION_WAIT_SECONDS = (ENV['RAID_ACTION_SECONDS'] || '300').to_i
ROUND_WAIT_SECONDS  = 0
CREATURE_COOLDOWN_KEY = '__creature__'.freeze
LOCATION_MAP = {}.freeze
BOT_USERNAME = '__raid__'.freeze


# ── battle/main.rb 에서 라운드 진행 함수만 그대로 불러오기 ─────────────────
MAIN_FUNCTIONS = %w[
  announce_prep_round handle_prep_input check_prep_completion
  announce_boss_turn announce_round process_action_for_session
  award_victory_credits! confiscate_defeat_credits! announce_scout_directions!
  announce_manual_battle_end! flush_pending_result! settle_session_if_needed
  select_auto_skill
].freeze

def load_main_functions!

# 보스 자동 행동: 그 보스에 지정된 스킬 중에서, 쿨타임이 돌아온 것, 직전 라운드와 다른 것을 무작위로 고른다.
# (선택지가 하나뿐이면 연속 사용 허용 — 확정 사양 "자동모드 연속 스킬 금지")
def select_auto_skill(creature, creature_sheet, ctx = nil)
  return nil unless creature && creature_sheet
  rows = boss_skill_rows(creature_sheet)
  all = rows.map { |r| [r[0].to_s.strip, r[3].to_s.strip.to_i] }.reject { |n, _| n.empty? }
  allowed = $raid_engine ? $raid_engine.boss_skill_list(creature[:name]) : []
  all = all.select { |n, _| allowed.include?(n) } if allowed.any?
  return nil if all.empty?
  pool = all
  if ctx.is_a?(Hash)
    cds = (ctx[:cooldowns] ||= Hash.new { |h, k| h[k] = {} })[CREATURE_COOLDOWN_KEY]
    ready = all.reject { |n, _| cds[n].to_i > 0 }
    pool = ready unless ready.empty?
    fresh = pool.reject { |n, _| n == ctx[:prev_boss_skill].to_s }
    pool = fresh unless fresh.empty?
  end
  pool.sample.first
rescue => e
  puts "[select_auto_skill 오류] #{e.class}: #{e.message}"
  nil
end
  src = File.read(File.join(BATTLE_DIR, 'main.rb'), encoding: 'UTF-8')
  lines = src.lines
  MAIN_FUNCTIONS.each do |name|
    start = lines.index { |l| l.start_with?("def #{name}(") }
    raise "battle/main.rb 에서 #{name} 함수를 찾지 못했습니다" unless start
    stop = (start + 1...lines.size).find { |i| lines[i].rstrip == 'end' }
    eval(lines[start..stop].join, TOPLEVEL_BINDING, File.join(BATTLE_DIR, 'main.rb'), start + 1)
  end
end
load_main_functions!

# ── 보스 스킬 범위 확장: 보스스킬 표의 "범위"에 '주변N' / '전방N' 을 쓰면
#    그 라운드 보스 위치·방향 기준으로 칸 목록을 계산해 기존 "칸 목록 공격" 규칙에 넘긴다.
alias __rule_apply_boss_skill_definition! apply_boss_skill_definition!
def apply_boss_skill_definition!(creature, creature_sheet)
  __rule_apply_boss_skill_definition!(creature, creature_sheet)
  m = creature[:skill_range_default].to_s.strip.match(/\A(주변|전방)\s*(\d+)\z/)
  if m && creature[:skill_range].to_s.strip.empty?
    cells = boss_area_cells(creature, m[1], m[2].to_i)
    creature[:skill_range] = creature[:pattern_cells] = cells.join(',') if cells.any?
  end
  creature
end

def boss_area_cells(creature, kind, n)
  body = BattleGrid.creature_cells(creature)
  pts = body.map { |c| BattleGrid.parse_pos(c) }.compact
  return [] if pts.empty? || n <= 0
  out = []
  if kind == '주변'
    xs = pts.map(&:first); ys = pts.map(&:last)
    ((xs.min - n)..(xs.max + n)).each do |x|
      ((ys.min - n)..(ys.max + n)).each do |y|
        c = BattleGrid.format_pos(x, y)
        out << c if c && !body.include?(c)
      end
    end
  else
    dx, dy = { '상' => [0, -1], '하' => [0, 1], '좌' => [-1, 0], '우' => [1, 0] }.fetch(creature[:facing].to_s.strip, [0, 1])
    pts.each do |x, y|
      (1..n).each do |k|
        c = BattleGrid.format_pos(x + dx * k, y + dy * k)
        out << c if c && !body.include?(c)
      end
    end
  end
  out.uniq
end

# ── 마스토돈 게시 대신: 웹 전투 기록에 남긴다 ──────────────────────────────
# 마스토돈용 안내 문구(입력 형식, 텍스트 격자맵)는 웹 화면에 이미 있으므로 기록에서 뺀다.
def web_log_text(text)
  out = []
  skip_map = false
  text.to_s.split("\n").each do |line|
    if line.strip == '전장'
      skip_map = true
      next
    end
    if skip_map
      skip_map = false if line.strip == '□ = 빈칸'
      next
    end
    next if line.match?(/DM 또는 멘션|\A형식|\A(공격|지원|방어|순간이동): \[|\A아이템 사용|\A입력 대기|초 후 다음 라운드|\A─+\z/)
    out << line
  end
  text = out.join("\n")
  RaidEngine::PASSIVES.each_value do |house, _n, label, _d, phrases|
    phrases.each { |ph| text = text.gsub(/\[#{house}\]( ?[^\n]*#{Regexp.escape(ph)})/) { "[#{label}]#{$1}" } }
  end
  text = text.gsub(/\[(그리핀도르|슬리데린|래번클로|후플푸프)\]/, '[팀 패시브]').gsub('[기숙사 패시브]', '[팀 패시브]')
  if $raid_engine
    $raid_engine.table_rows('runner', '스탯').each do |r|
      id = r[0].to_s.strip
      next if id.empty? || r[1].to_s.strip.empty?
      text = text.gsub(/(?<![A-Za-z0-9_])#{Regexp.escape(id)}(?![A-Za-z0-9_])/, r[1].to_s.strip)
    end
  end
  text.gsub('순간이동', '이동').gsub(/\n{3,}/, "\n\n").strip
end

def post_session_thread(session, text, last_post_time)
  WebState.record_post(session, web_log_text(text))
  id = "web-#{SecureRandom.hex(4)}"
  [{ 'id' => id, 'all_ids' => [id], 'partial' => false }, Time.now]
end

def sheet_log(creature_sheet, session_id, round, event, detail)
  creature_sheet.append_battle_log([Time.now.strftime('%Y-%m-%d %H:%M:%S'), session_id.to_s, round.to_s, event.to_s, detail.to_s])
rescue => e
  puts "[기록 실패] #{e.message}"
end

# 전투 중 회복 아이템: 원래 규칙(물약 = 사거리 제한 없음, 대상 1명, 소지품 확인, 정산 뒤 차감)을
# 그대로 쓰되, 물약 목록과 소지품을 관리자 화면의 '아이템' 표와 러너의 '소지품' 칸에서 읽는다.
module BattleItems
  def self.potion?(skill_name)
    $raid_engine ? $raid_engine.heal_item?(skill_name) : false
  end

  def self.owned?(account, skill_name)
    $raid_engine ? $raid_engine.item_count(account, skill_name).positive? : nil
  end

  def self.consume!(account, skill_name)
    $raid_engine ? $raid_engine.consume_item!(account, skill_name) : false
  end
end

# 마스토돈 DM 대신 참여자 화면에 안내 문구를 띄운다.
class WebListener
  def initialize
    @notices = {}
  end

  def send_dm(username, text)
    @notices[username.to_s] = { 'text' => text.to_s, 'at' => Time.now.to_i }
  end

  def notice_for(username)
    @notices[username.to_s]
  end

  def clear(username)
    @notices.delete(username.to_s)
  end
end

class RaidEngine
  attr_reader :store, :runner_sheet, :creature_sheet, :sessions, :mutex, :version

  def initialize(data_path)
    @store = LocalStore.new(data_path, File.join(APP_DIR, 'data', 'sample.json'))
    @runner_sheet = LocalSheet.new(@store, 'runner')
    @creature_sheet = LocalSheet.new(@store, 'creature')
    @listener = WebListener.new
    @sessions = {}
    @tokens = {}
    @mutex = Monitor.new
    @last_post_time = Time.at(0)
    @version = 1
    @last_snapshot = nil
    @admin_sessions = {}
    @login_fails = Hash.new { |h, k| h[k] = [] }
    @cheers = Hash.new { |h, k| h[k] = { 'counts' => Hash.new(0), 'recent' => [] } }
    @cheer_last = {}
    @watchers = {}
    @chats = Hash.new { |h, k| h[k] = [] }
    @joined = Hash.new { |h, k| h[k] = Set.new } # 전투 id => 링크로 들어온 러너
    @lobby = {} # 전투 id => 준비완료 누른 러너 Set (관리자가 시작 누르기 전 대기실)
    @events = Hash.new { |h, k| h[k] = [] }
    @event_seq = 0
    @chat_last = {}
    settings['admin_key'] ||= SecureRandom.alphanumeric(10)
    unless @store.book('app')['스킬']
      rows = SkillCatalog.default_rows
      if settings['skills'].is_a?(Array)
        rows[1..].each { |r| r[12] = settings['skills'].include?(r[0]) ? 'O' : '' }
      end
      @store.book('app')['스킬'] = rows
    end
    settings.delete('skills')
    migrate_tables!
    $raid_engine = self
    install_skills!
    add_equipment_bonus!(@runner_sheet)
    @store.save!
  end

  RUNNER_HEADER = %w[ID 이름 팀 패시브선택 건강 내구도 마법능력 민첩 기술 행운 최대건강 스킬2 방향 역할 이미지 장비 소지품 크레딧].freeze
  ITEM_HEADER = %w[이름 종류 회복량 내구도 마법능력 민첩 기술 행운 설명].freeze
  ITEM_TYPES = %w[회복 무기 갑옷 장신구].freeze
  # 아이템 표의 보너스 칸 번호 → 전투 스탯 키
  ITEM_BONUS = { 3 => :dur, 4 => :atk, 5 => :agi, 6 => :tec, 7 => :luck }.freeze
  ROLE_RENAME = { '탱커' => '수호', '딜러' => '공격', '힐러' => '지원' }.freeze

  # 팀 패시브: 계산은 기존 규칙(기숙사 패시브 8종)을 그대로 쓰고, 화면에는 이 이름으로만 보인다.
  # 코드 => [규칙 내부 이름, 패시브 번호, 보이는 이름, 설명, 기록에서 찾을 문구들]
  PASSIVES = {
    'front_guard' => ['그리핀도르', '1', '정면 수호', '보스 정면 1칸에 서 있으면 내구도 +50%', ['적 정면']],
    'last_stand'  => ['그리핀도르', '2', '역경', '건강이 40% 미만이면 마법능력 +50%', ['건강 40%']],
    'unscathed'   => ['슬리데린', '1', '무결', '이전 라운드에 피해가 없었으면 마법능력 +50%', ['이전 라운드 무피해']],
    'watchful'    => ['슬리데린', '2', '관망', '관찰(행동 포기)하면 다음 라운드부터 행운 +10', ['관찰 보너스', '행동을 포기']],
    'insight'     => ['래번클로', '1', '통찰', '보스가 상태이상이면 마법능력 +50%', ['적 상태이상']],
    'adapt'       => ['래번클로', '2', '변통', '직전 라운드와 다른 분류의 행동을 하면 기술 +10', ['행동 분류']],
    'endure'      => ['후플푸프', '1', '인내', '이전 라운드에 맞았으면 내구도 +50%', ['이전 라운드 피격']],
    'survive'     => ['후플푸프', '2', '불굴', '전투 중 1회, 건강이 0 이하가 되는 것을 막음', ['전투 중 1회', '건강 0 이하', '패시브로']]
  }.freeze
  TEAM_HEADER = %w[ID 이름 패시브1 패시브2 설명].freeze
  DEFAULT_TEAMS = [
    ['team1', '선봉대', 'front_guard', 'last_stand', '앞에 서서 버티는 팀', '그리핀도르'],
    ['team2', '그림자단', 'unscathed', 'watchful', '피해를 피하며 기회를 노리는 팀', '슬리데린'],
    ['team3', '탐구회', 'insight', 'adapt', '상황을 읽고 바꿔 가며 싸우는 팀', '래번클로'],
    ['team4', '수호단', 'endure', 'survive', '맞으며 버티는 팀', '후플푸프']
  ].freeze

  def team_rows
    table_rows('app', '팀').reject { |r| r[0].to_s.strip.empty? }
  end

  def team_row(id)
    team_rows.find { |r| r[0].to_s.strip == id.to_s.strip }
  end

  # 러너의 팀·패시브 선택(1/2) → 기존 규칙이 알아듣는 기숙사·패시브 번호
  def rule_passive(team_id, pick)
    team = team_row(team_id) or return ['', '']
    code = team[pick.to_s == '2' ? 3 : 2].to_s
    pas = PASSIVES[code] or return ['', '']
    [pas[0], pas[1]]
  end

  def passive_info(team_id, pick)
    team = team_row(team_id) or return nil
    pas = PASSIVES[team[pick.to_s == '2' ? 3 : 2].to_s]
    { 'team' => team[1].to_s, 'passive' => pas ? pas[2] : '', 'desc' => pas ? pas[3] : '' }
  end
  CREATURE_HEADER = %w[활성 이름 위치 크기 현재스킬 건강 내구도 마법능력 민첩 기술 행운 비고 보상크레딧 명중기본 회피기본 방향 스킬목록 이미지 패배압수].freeze

  # 예전 데이터 파일에 새 칸(역할/이미지/스킬목록)을 붙이고, 순간이동을 1칸 이동으로 바꾼다.
  def migrate_tables!
    { ['runner', '스탯'] => RUNNER_HEADER, ['creature', '스탯'] => CREATURE_HEADER }.each do |(book, tab), header|
      rows = (@store.book(book)[tab] ||= [header.dup])
      rows[0] = header.dup if rows[0].nil? || rows[0].size < header.size
      rows[1..].each { |r| r.push('') while r.size < header.size }
    end
    (@store.book('app')['스킬'] || []).each do |r|
      next unless r[2].to_s == 'teleport'
      r[0] = '이동'
      r[3] = '1칸'
    end
    # 역할 이름은 탱/딜/힐 대신 수호/공격/지원
    table_rows('runner', '스탯').each { |r| r[13] = ROLE_RENAME.fetch(r[13].to_s, r[13].to_s) }
    boss = @store.book('creature')['보스스킬'] || []
    if boss[1..].to_a.any? { |r| r[0] == '탱커 버스터' } && boss[1..].to_a.none? { |r| r[0] == '집중 강타' }
      boss[1..].each do |r|
        r[0] = '집중 강타' if r[0] == '탱커 버스터'
        r[10] = r[10].to_s.gsub('탱커가 아니면 위험', '내구도 높은 러너가 받아야 안전').gsub('탱커 대상', '한 명에게').gsub('탱커를', '앞에 선 러너를')
      end
      table_rows('creature', '스탯').each { |r| r[16] = r[16].to_s.sub('탱커 버스터', '집중 강타') }
    end
    unless @store.book('app')['아이템']
      sample = JSON.parse(File.read(File.join(APP_DIR, 'data', 'sample.json'), encoding: 'UTF-8'))
      @store.book('app')['아이템'] = sample.dig('books', 'app', '아이템') || [ITEM_HEADER.dup]
    end
    table_rows('runner', '스탯').each { |r| r[17] = '0' if r[17].to_s.empty? }
    unless @store.book('app')['팀']
      @store.book('app')['팀'] = [TEAM_HEADER.dup] + DEFAULT_TEAMS.map { |t| t.first(5) }
      by_house = DEFAULT_TEAMS.to_h { |t| [t[5], t[0]] }
      (@store.book('runner')['스탯'] || [])[0]&.then { |h| h[2] = '팀' }
      table_rows('runner', '스탯').each { |r| r[2] = by_house.fetch(r[2].to_s.strip, r[2].to_s) }
    end
  end

  # ── 아이템 ────────────────────────────────────────────────
  def item_rows
    table_rows('app', '아이템').reject { |r| r[0].to_s.strip.empty? }
  end

  def item_row(name)
    n = BattleItems.norm(name)
    item_rows.find { |r| BattleItems.norm(r[0]) == n }
  end

  def heal_item?(name)
    item_row(name).to_a[1].to_s == '회복'
  end

  def runner_row(id)
    table_rows('runner', '스탯').find { |r| r[0].to_s.strip == id.to_s.strip }
  end

  # "회복 물약:2,고급 회복 물약:1" → { "회복 물약" => 2, ... }
  def inventory(id)
    runner_row(id).to_a[16].to_s.split(',').each_with_object({}) do |part, h|
      name, cnt = part.split(':', 2).map(&:strip)
      next if name.to_s.empty?
      h[name] = (h[name] || 0) + (cnt.to_s.empty? ? 1 : cnt.to_i)
    end
  end

  def item_count(id, name)
    n = BattleItems.norm(name)
    inventory(id).sum { |k, v| BattleItems.norm(k) == n ? v : 0 }
  end

  def consume_item!(id, name)
    row = runner_row(id) or return false
    inv = inventory(id)
    key = inv.keys.find { |k| BattleItems.norm(k) == BattleItems.norm(name) && inv[k].positive? } or return false
    inv[key] -= 1
    row[16] = inv.reject { |_, v| v <= 0 }.map { |k, v| "#{k}:#{v}" }.join(',')
    @store.save!
    true
  end

  def equipment(id)
    names = runner_row(id).to_a[15].to_s.split(',').map(&:strip)
    names.filter_map { |n| item_row(n) }.reject { |r| r[1].to_s == '회복' }
  end

  def equipment_bonus(id)
    equipment(id).each_with_object(Hash.new(0)) do |r, h|
      ITEM_BONUS.each { |col, key| h[key] += r[col].to_i }
    end
  end

  def bonus_text(row)
    labels = { 3 => '내구도', 4 => '마법능력', 5 => '민첩', 6 => '기술', 7 => '행운' }
    labels.filter_map { |c, l| v = row[c].to_i; "#{l} #{v.positive? ? '+' : ''}#{v}" unless v.zero? }.join(', ')
  end

  # 전투 스탯을 읽을 때 장비 보너스를 더한다 (표의 원래 값은 그대로).
  def add_equipment_bonus!(sheet)
    engine = self
    sheet.define_singleton_method(:read_base_stats) do
      super().map do |st|
        bonus = engine.equipment_bonus(st[:id])
        st = st.merge(bonus.to_h { |k, v| [k, st[k].to_i + v] }) unless bonus.empty?
        house, num = engine.rule_passive(st[:house], st[:passive])
        st.merge(house: house, passive: num)
      end
    end
  end

  # 러너 스킬 표 + 회복 아이템 → BattleSkills::SKILLS
  def install_skills!
    table = SkillCatalog.build(@store.book('app')['스킬']).dup
    item_rows.each do |r|
      next unless r[1].to_s == '회복'
      table[r[0].to_s.strip] = { category: '지원', range: '제한 없음', cooldown: 0, kind: :heal_fixed, value: r[2].to_i }.freeze
    end
    BattleSkills.send(:remove_const, :SKILLS)
    BattleSkills.const_set(:SKILLS, table.freeze)
  end

  def table_rows(book, tab)
    (@store.book(book)[tab] || [])[1..].to_a
  end

  # 보스(크리쳐)에 지정된 스킬 목록. 비어 있으면 전체 보스 스킬을 쓴다.
  def boss_skill_list(creature_name)
    row = table_rows('creature', '스탯').find { |r| r[1].to_s.strip == creature_name.to_s.strip }
    row.to_a[16].to_s.split(',').map(&:strip).reject(&:empty?)
  end

  # 관전/참여 화면용: 역할·이미지 같은 꾸밈 정보를 덧붙인 전투 상태
  def public_json
    data = JSON.parse(WebState.public_battles)
    runners = table_rows('runner', '스탯').to_h { |r| [r[0].to_s.strip, r] }
    creatures = table_rows('creature', '스탯').to_h { |r| [r[1].to_s.strip, r] }
    data['battles'].each do |b|
      sess = @sessions[b['id']]
      chosen = sess ? sess.passive_ctx[:positions].to_h : {}
      if sess && lobby?(sess.id)
        b['phase'] = 'lobby'
        b['ready'] = @lobby[sess.id].to_a
        # 대기실: 전투 시작 전이라 상태가 비어 있으니, 지금 저장된 러너 정보로 보여 준다 (관리자가 고치면 바로 반영)
        base = @runner_sheet.read_base_stats
        b['runners'] = sess.runner_names.map do |n|
          st = base.find { |x| x[:name].to_s == n } || {}
          { 'name' => n, 'display' => st[:display_name].to_s.empty? ? n : st[:display_name].to_s,
            'hp' => st[:hp].to_i, 'max_hp' => [st[:max_hp].to_i, st[:hp].to_i, 1].max, 'pos' => nil }
        end
      end
      b['runners'].each do |r|
        # 준비 라운드: 시작 칸을 고르기 전에는 격자에 안 보이게
        r['pos'] = nil if sess && (lobby?(sess.id) || sess.phase == :prep) && chosen[r['name']].to_s == ''
        row = runners[r['name']] || []
        r['role'] = row[13].to_s
        r['img'] = row[14].to_s
        r['house'] = team_row(row[2]).to_a[1].to_s
      end
      c = creatures[b.dig('creature', 'name').to_s] || []
      cheer = @cheers[b['id']]
      b['cheers'] = { 'counts' => cheer['counts'], 'recent' => cheer['recent'].last(12).reverse }
      b['watchers'] = watcher_names
      b['chat'] = @chats[b['id']].last(80)
      b['events'] = @events[b['id']].last(20)
      b['creature']['img'] = c[17].to_s
      b['creature']['omen'] = @sessions[b['id']]&.creature&.dig(:omen).to_s
    end
    JSON.generate(data)
  end

  # 화면들이 "바뀐 게 있나?" 를 묻는 번호. 무언가 바뀔 때마다 1씩 오른다.
  def bump!
    @version += 1
  end

  # 바뀔 때까지(최대 timeout초) 기다렸다가 현재 번호를 돌려준다. 다른 창의 변화가 바로 반영되는 원리.
  def wait_change(since, timeout = 20)
    deadline = Time.now + timeout
    sleep 0.2 while @version <= since.to_i && Time.now < deadline
    @version
  end

  def settings
    @store.to_h['settings'] ||= {}
  end

  def admin_key
    settings['admin_key']
  end

  def skills
    SkillCatalog.visible(@store.book('app')['스킬'])
  end

  # 이 러너가 쓸 수 있는 스킬: 모두에게 보이는 기본 스킬 + 러너 전용 스킬
  def skills_for(name)
    rows = @store.book('app')['스킬']
    base = SkillCatalog.visible(rows)
    extra = SkillCatalog.extra(rows, runner_row(name).to_a[11]).reject { |x| base.any? { |b| b[:name] == x[:name] } }
    base + extra
  end

  # ── 데이터(스탯 표) ──────────────────────────────────────────
  TABLES = {
    'runners'     => ['runner', '스탯'],
    'creatures'   => ['creature', '스탯'],
    'boss_skills' => ['creature', '보스스킬'],
    'runner_skills' => ['app', '스킬'],
    'items' => ['app', '아이템'],
    'teams' => ['app', '팀']
  }.freeze

  def check_unique!(rows, col, label)
    seen = {}
    Array(rows)[1..].to_a.each do |r|
      v = r[col].to_s.strip
      raise "#{label}이(가) 비어 있는 줄이 있습니다." if v.empty?
      raise "#{label} '#{v}'이(가) 두 번 있습니다." if seen[v]
      seen[v] = true
    end
  end

  def tables
    TABLES.transform_values { |(book, tab)| @store.book(book)[tab] || [] }
  end

  def save_table!(key, rows)
    book, tab = TABLES.fetch(key) { raise '알 수 없는 표입니다.' }
    rows = Array(rows).map { |r| Array(r).map { |v| v.to_s.strip } }
    case key
    when 'runners'
      check_unique!(rows, 0, 'ID')
      ids = team_rows.map { |r| r[0].to_s }
      rows[1..].to_a.each { |r| raise "'#{r[1]}'의 팀을 목록에서 골라 주세요." unless r[2].to_s.empty? || ids.include?(r[2].to_s) }
    when 'creatures' then check_unique!(rows, 1, '이름')
    when 'boss_skills' then check_unique!(rows, 0, '스킬명')
    when 'runner_skills' then SkillCatalog.validate!(rows)
    when 'items' then validate_items!(rows)
    when 'teams'
      check_unique!(rows, 0, '팀 ID')
      check_unique!(rows, 1, '팀 이름')
      used = table_rows('runner', '스탯').map { |r| r[2].to_s.strip }.reject(&:empty?)
      gone = used - rows[1..].to_a.map { |r| r[0].to_s }
      raise "아직 이 팀에 속한 러너가 있어 지울 수 없습니다: #{gone.uniq.join(', ')}" if gone.any?
      rows[1..].to_a.each do |r|
        [r[2], r[3]].each { |c| raise "'#{r[1]}'의 패시브를 목록에서 골라 주세요." unless c.to_s.empty? || PASSIVES.key?(c.to_s) }
      end
    end
    @store.replace_tab!(book, tab, rows)
    install_skills! if %w[runner_skills items].include?(key)
    @runner_sheet.invalidate_base_stats_cache!
    $boss_skill_cache = nil
    bump!
  end

  def validate_items!(rows)
    check_unique!(rows, 0, '아이템 이름')
    skill_names = (@store.book('app')['스킬'] || [])[1..].to_a.map { |r| r[0].to_s.strip }
    rows[1..].to_a.each do |r|
      name = r[0].to_s
      raise "아이템 이름에는 [ ] / , : 를 쓸 수 없습니다: #{name}" if name.match?(%r{[\[\]/,:]})
      raise "'#{name}'은(는) 러너 스킬 이름과 같아서 쓸 수 없습니다." if skill_names.include?(name)
      raise "'#{name}'의 종류를 골라 주세요." unless ITEM_TYPES.include?(r[1].to_s)
      raise "'#{name}'의 회복량을 1 이상으로 넣어 주세요." if r[1] == '회복' && r[2].to_i <= 0
    end
  end

  def heal_all!
    rows = @store.book('runner')['스탯'] || []
    rows[1..].to_a.each { |r| r[4] = r[10].to_s if r[10].to_s.match?(/\A\d+\z/) }
    @store.save!
    @runner_sheet.invalidate_base_stats_cache!
    bump!
  end

  def runner_ids
    (@store.book('runner')['스탯'] || [])[1..].to_a.map { |r| r[0].to_s.strip }.reject(&:empty?)
  end

  def creature_names
    (@store.book('creature')['스탯'] || [])[1..].to_a.map { |r| r[1].to_s.strip }.reject(&:empty?)
  end

  def boss_skill_names
    (@store.book('creature')['보스스킬'] || [])[1..].to_a.map { |r| r[0].to_s.strip }.reject(&:empty?)
  end

  # ── 전투 시작/종료 ──────────────────────────────────────────
  def start_battle!(runners:, creature_name:, auto_mode: false, positions: {}, hps: {})
    runners = Array(runners).map { |r| r.to_s.strip }.reject(&:empty?).uniq
    raise '참여자를 한 명 이상 고르세요.' if runners.empty?
    busy = runners.select { |r| @sessions.values.any? { |s| s.active && s.includes_runner?(r) } }
    raise "이미 전투 중인 참여자가 있습니다: #{busy.join(', ')}" if busy.any?

    creature = creature_from_stats_sheet_by_name(@creature_sheet, creature_name)
    raise "크리쳐 '#{creature_name}'을(를) 찾지 못했습니다." unless creature
    creature[:pos] = 'D4' if creature[:pos].to_s.strip.empty?

    # 관리자가 넣은 시작 체력 (최대 건강을 넘으면 최대 건강으로)
    hps.to_h.each do |id, hp|
      next unless runners.include?(id.to_s) && hp.to_s.strip.match?(/\A\d+\z/)
      row = runner_row(id) or next
      max = row[10].to_i.positive? ? row[10].to_i : hp.to_i
      raise "#{row[1].to_s.empty? ? id : row[1]}의 시작 체력은 1 이상이어야 합니다." if hp.to_i < 1
      row[4] = [hp.to_i, max].min.to_s
    end
    @store.save!
    @runner_sheet.invalidate_base_stats_cache!

    id = Time.now.strftime('%Y%m%d%H%M%S') + SecureRandom.hex(2)
    session = BattleSession.new(id: id, mode: :public, runner_names: runners, creature: creature.dup)
    session.auto_mode = auto_mode ? true : false
    session.dm_visibility = false
    @sessions[session.id] = session
    tokens = runners.to_h { |r| [r, SecureRandom.urlsafe_base64(9)] }
    tokens.each { |r, t| @tokens[t] = [session.id, r] }
    session.instance_variable_set(:@web_tokens, tokens)
    # 관리자가 정해 준 시작 위치 (안 정한 사람은 준비 라운드에서 직접 고름)
    taken = BattleGrid.creature_cells(creature)
    positions.to_h.each do |name, pos|
      pos = pos.to_s.strip.upcase
      next unless runners.include?(name.to_s) && BattleGrid.valid_pos?(pos)
      raise "#{pos}는 크리쳐가 있거나 이미 다른 러너가 고른 칸입니다." if taken.include?(pos)
      taken << pos
      (session.passive_ctx[:positions] ||= {})[name.to_s] = pos
    end
    sheet_log(@creature_sheet, session.id, session.round, '전투 시작', "참여자: #{runners.join(', ')} / 상대: #{creature[:name]}")
    @lobby[session.id] = Set.new
    tick!
    session
  end

  def lobby?(id)
    @lobby.key?(id.to_s)
  end

  # 러너: 링크를 열고 [준비 완료]
  def player_ready!(token, on = true)
    s, name = player_for(token)
    raise '링크가 올바르지 않거나 끝난 전투입니다.' unless s && s.active
    raise '이미 전투가 시작됐어요.' unless lobby?(s.id)
    was = @lobby[s.id].include?(name)
    on ? @lobby[s.id] << name : @lobby[s.id].delete(name)
    WebState.record_post(s, "#{display_of(name)} #{on ? '준비 완료' : '준비 취소'}") if was != on
    bump!
  end

  # 관리자: 모두 준비되면 [전투 시작] → 그때부터 시작 위치 고르기(타이머 시작)
  def begin_battle!(id)
    s = @sessions[id.to_s] or raise '전투를 찾지 못했습니다.'
    raise '이미 시작한 전투입니다.' unless lobby?(s.id)
    @lobby.delete(s.id)
    WebState.record_post(s, '진행자가 전투를 시작했습니다. 시작 위치를 고르세요.')
    s.start_time = Time.now
    tick!
  end

  def end_battle!(session_id)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    s.active = false
    s.auto_next_round_timer = nil
    s.awaiting_boss = false
    s.instance_variable_set(:@web_finish_noted, true)
    @last_post_time = announce_manual_battle_end!(s, nil, nil, @last_post_time)
    sheet_log(@creature_sheet, s.id, s.round, '전투 중단', '관리자 종료')
  end

  def set_auto!(session_id, on)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    s.auto_mode = on ? true : false
    if s.auto_mode && s.awaiting_boss
      skill = select_auto_skill(s.creature, @creature_sheet, s.passive_ctx)
      boss_command!(s.id, skill: skill) if skill
    end
  end

  # 보스 행동 지정 (기존 [보스행동커맨드/스킬/대상 또는 좌표] 와 같은 효과)
  def boss_command!(session_id, skill:, targets: [], cells: [])
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    raise '지금은 보스 행동을 입력하는 단계가 아닙니다.' unless s.active && s.awaiting_boss
    skill = skill.to_s.strip
    raise '보스 스킬을 고르세요.' if skill.empty?
    override = { skill: skill }
    cells = Array(cells).map { |c| c.to_s.strip.upcase }.select { |c| BattleGrid.valid_pos?(c) }
    targets = Array(targets).map { |t| t.to_s.strip }.reject(&:empty?) & s.runner_names
    if cells.any?
      override[:cells] = cells
    elsif targets.any?
      override[:targets] = targets
    end
    s.passive_ctx[:boss_override] = override
    s.awaiting_boss = false
    s.phase = :announcing
    s.announced = false
    s.actions = {}
    s.processed_messages = {}
    s.start_time = Time.now
    sheet_log(@creature_sheet, s.id, s.round, '보스행동 지정', "#{skill} #{(cells + targets).join(', ')}")
    tick!
  end

  # 입력 대기 시간을 끝내고 바로 정산 (미제출자는 턴 상실)
  def settle_now!(session_id)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    raise '행동 입력 중이 아닙니다.' unless s.phase == :battle || s.phase == :prep
    s.start_time = Time.now - ACTION_WAIT_SECONDS - 1
    tick!
  end

  # 승리: 보스에 정한 보상만큼 참여자 전원 크레딧 +, 패배(전원 전투불능): 정한 만큼 압수 (모자라면 마이너스)
  def settle_credits!(s, text)
    crow = table_rows('creature', '스탯').find { |r| r[1].to_s.strip == s.creature[:name].to_s.strip }.to_a
    if text.start_with?('[승리]')
      amount = crow[12].to_i
      return '' unless amount.positive?
      s.runner_names.each { |id| (row = runner_row(id)) && row[17] = (row[17].to_i + amount).to_s }
      @store.save!
      "\n[보상] 참여자 전원 크레딧 +#{amount}"
    elsif text.start_with?('[패배]')
      amount = crow[18].to_i
      return '' unless amount.positive?
      lines = s.runner_names.map do |id|
        row = runner_row(id) or next
        before = row[17].to_i
        row[17] = (before - amount).to_s
        "#{display_of(id)} #{before} → #{row[17]}"
      end.compact
      @store.save!
      "\n[압수] 참여자 전원 크레딧 -#{amount}\n#{lines.join("\n")}"
    else
      ''
    end
  end

  # ── 화면 가운데 띄우는 발동 알림 (오버레이) ──────────────────
  def add_event!(s, kind, who, name, text = '', extra = {})
    @event_seq += 1
    list = @events[s.id]
    list << { 'seq' => @event_seq, 'bid' => s.id, 'kind' => kind, 'who' => who.to_s, 'name' => name.to_s, 'text' => text.to_s, 'at' => Time.now.to_i }.merge(extra)
    list.shift while list.size > 40
  end

  def display_of(id)
    d = runner_row(id).to_a[1].to_s
    d.empty? ? id.to_s : d
  end

  # 한 틱 전후를 비교해: 정산이 끝났으면 러너 스킬 → 보스 스킬 순으로, 새 라운드가 열리면 보스 전조를 알린다.
  def overlay_events!(s, before)
    if before[:phase] == :battle && s.phase != :battle
      before[:actions].each do |name, a|
        type = a[:type].to_s.sub('순간이동', '이동')
        next if type.empty? || type == '관찰'
        target = a[:target].to_s.split(',').map { |t| s.runner_names.include?(t.strip) ? display_of(t.strip) : t.strip }.join(', ')
        add_event!(s, 'skill', display_of(name), type, target)
      end
      add_event!(s, 'boss', s.creature[:name], before[:skill], before[:single] ? target_label(s, before[:target]) : '') unless before[:skill].empty?
    end
    if s.phase == :battle && (before[:phase] != :battle || before[:round] != s.round)
      omen = s.creature[:omen].to_s.strip
      add_event!(s, 'omen', s.creature[:name], s.creature[:current_skill].to_s, omen) unless omen.empty?
      c = s.creature
      single = c[:current_skill].to_s != '전체공격' && BattleBossPatterns.range_shape(c) != '전체' && BattleBossPatterns.pattern_cells(c).empty?
      who = single ? target_label(s, c[:skill_target]) : ''
      add_event!(s, 'target', s.creature[:name], s.creature[:current_skill].to_s, who) unless who.empty?
    end
  end

  # 보스가 노리는 러너 ID들 → 표시 이름
  def target_label(s, ids)
    ids.to_s.split(',').map(&:strip).reject(&:empty?).map { |t| s.runner_names.include?(t) ? display_of(t) : t }.join(', ')
  end

  # 승리/패배 안내 (기존 봇은 조사봇 시트에 보상을 주며 안내했지만, 웹앱에서는 기록만 남긴다)
  def announce_finish!(s)
    return if s.instance_variable_get(:@web_finish_noted)
    s.instance_variable_set(:@web_finish_noted, true)
    text = if s.creature[:hp].to_i <= 0
             "[승리] #{s.creature[:name]} 처치!"
           elsif s.passive_ctx.key?(:escaped_by) || s.dead_runners.size < s.runner_names.size
             '[전투 종료]'
           else
             "[패배] #{s.creature[:name]}에게 전원 전투불능"
           end
    text += settle_credits!(s, text)
    post_session_thread(s, text, @last_post_time)
    alive = s.runner_names.reject { |n| s.dead_runners.include?(n) }.map { |n| display_of(n) }
    winners = text.start_with?('[승리]') ? alive : text.start_with?('[패배]') ? [s.creature[:name].to_s] : []
    add_event!(s, 'end', s.creature[:name], text.sub(/\A\[(.+?)\].*/m, '\\1'), text, 'winners' => winners, 'all' => s.runner_names.map { |n| display_of(n) })
  end

  # ── 참여자 ──────────────────────────────────────────────────
  def player_for(token)
    sid, name = @tokens[token.to_s]
    s = sid && @sessions[sid]
    [s, name]
  end

  def player_submit!(token, command)
    s, name = player_for(token)
    raise '링크가 올바르지 않거나 끝난 전투입니다.' unless s && s.active
    raise '관리자가 전투를 시작하면 시작 위치를 고를 수 있어요.' if lobby?(s.id)
    @listener.clear(name)
    case s.phase
    when :prep
      if (m = command.to_s.match(/\[([A-Ga-g][1-8])\]/))
        other = s.passive_ctx[:positions].to_h.find { |n, p| n != name && p.to_s.upcase == m[1].upcase }
        raise "#{m[1].upcase}에는 이미 다른 러너가 있습니다." if other
      end
      handle_prep_input(s, name, command, Set.new, SecureRandom.hex(4), @listener)
    when :battle
      raise '이미 이번 라운드 행동을 제출했습니다.' if s.processed_messages[name]
      command = convert_move!(s, name, command)
      process_action_for_session(s, name, command, Set.new, SecureRandom.hex(4), @runner_sheet, @runner_sheet, @listener)
    else
      raise '지금은 행동을 입력하는 단계가 아닙니다.'
    end
    notice = @listener.notice_for(name)
    log_plan!(s, name, command) unless notice
    tick!
    notice
  end

  # 전투 기록: "애셔 그레이 > 심핵 공격 예정", "애셔 그레이 > 시작 위치 C3"
  def log_plan!(s, name, command)
    who = display_of(name)
    if s.phase == :prep || s.passive_ctx[:positions].to_h[name] && command.to_s.match?(/\A\[[A-Ga-g][1-8]\]\z/)
      pos = command.to_s[/[A-Ga-g][1-8]/].to_s.upcase
      return WebState.record_post(s, "#{who} > 시작 위치 #{pos}") unless pos.empty?
    end
    a = s.actions[name] or return
    type = a[:type].to_s.sub('순간이동', '이동')
    tgt = a[:target].to_s.split(',').map(&:strip).reject(&:empty?).map { |t| s.runner_names.include?(t) ? display_of(t) : t }
    text = if type == '이동' then "이동(#{tgt.join}) 예정"
           elsif tgt.any? then "#{tgt.join(', ')} #{type} 예정"
           else "#{type} 예정"
           end
    WebState.record_post(s, "#{who} > #{text}")
  rescue => e
    puts "[기록 오류] #{e.message}"
  end

  # [이동/C3] → 가로·세로·대각선 1칸만 허용한 뒤, 기존 규칙의 [순간이동/C3] 으로 넘긴다.
  def convert_move!(s, name, command)
    m = command.to_s.match(/\[이동\/([A-Ga-g][1-8])\]/)
    return command unless m
    to = m[1].upcase
    from = s.passive_ctx[:positions].to_h[name].to_s
    state = merge_runner_state(@runner_sheet, @runner_sheet, s.runner_names, 'D3')
    state.each { |r| p = s.passive_ctx[:positions].to_h[r[:name].to_s]; r[:pos] = p if p }
    ok, msg = BattleGrid.movable?(from, to, state, s.creature, actor_name: name, teleport: false)
    raise msg unless ok
    "[순간이동/#{to}]"
  end

  def player_view(token)
    s, name = player_for(token)
    return nil unless s
    if s.active && !@joined[s.id].include?(name)
      @joined[s.id] << name
      WebState.record_post(s, "#{display_of(name)} 입장")
      bump!
    end
    ctx = s.passive_ctx
    base = @runner_sheet.read_base_stats
    stat = base.find { |b| b[:name].to_s == name } || {}
    {
      'battle_id' => s.id,
      'me' => name,
      'display' => stat[:display_name].to_s.empty? ? name : stat[:display_name],
      'phase' => lobby?(s.id) ? 'lobby' : s.phase.to_s,
      'ready' => lobby?(s.id) && @lobby[s.id].include?(name),
      'card' => {
        'img' => runner_row(name).to_a[14].to_s, 'role' => runner_row(name).to_a[13].to_s,
        'hp' => stat[:hp].to_i, 'max_hp' => [stat[:max_hp].to_i, stat[:hp].to_i, 1].max,
        'stats' => [['내구도', stat[:dur]], ['마법능력', stat[:atk]], ['민첩', stat[:agi]], ['기술', stat[:tec]], ['행운', stat[:luck]]].map { |l, v| [l, v.to_i] }
      },
      'active' => s.active,
      'round' => s.round,
      'my_pos' => ctx[:positions].to_h[name],
      'submitted' => s.actions[name] ? { 'type' => s.actions[name][:type].to_s.sub('순간이동', '이동'), 'target' => s.actions[name][:target] } : nil,
      'prep_done' => s.phase == :prep && ctx[:positions].to_h[name].to_s != '',
      'notice' => @listener.notice_for(name),
      'team' => passive_info(runner_row(name).to_a[2], runner_row(name).to_a[3]),
      'equipment' => equipment(name).map { |r| { 'name' => r[0], 'type' => r[1], 'bonus' => bonus_text(r) } },
      'items' => item_rows.select { |r| r[1] == '회복' }.filter_map do |r|
        c = item_count(name, r[0])
        { 'name' => r[0], 'count' => c, 'value' => r[2].to_i, 'desc' => r[8].to_s, 'target' => 'runner', 'range' => '제한 없음', 'max_targets' => 1, 'item' => true } if c.positive?
      end,
      'skills' => skills_for(name).map do |item|
        sk = item[:name]
        d = BattleSkills.get(sk) || {}
        kind = item[:kind]
        {
          'name' => sk,
          'kind' => kind,
          'category' => kind == 'teleport' ? '이동' : (kind == 'pass' ? '대기' : d[:category]),
          'range' => kind == 'teleport' ? '1칸 (8방향)' : d[:range].to_s,
          'cooldown' => d[:once] ? '1회' : d[:cooldown].to_i,
          'max_targets' => [d[:max_targets].to_i, 1].max,
          'desc' => SkillCatalog::KINDS[kind].to_s,
          'target' => target_kind(kind, d),
          'left' => ctx[:cooldowns][name][sk].to_i,
          'used_once' => d[:once] && ctx[:once_used][name][sk] ? true : false
        }
      end
    }
  end

  # 참여자 화면에서 무엇을 고르게 할지: none / creature / creature_cell / runner / runner_cell / runner_skill / cell
  def target_kind(kind, d)
    return 'cell' if kind == 'teleport'
    return 'none' if kind == 'pass'
    return 'creature_cell' if kind == 'rush'
    return 'creature' if d[:category] == '공격'
    return 'none' if d[:range].to_s == '자신' || SkillCatalog::AREA_KINDS.include?(kind)
    return 'runner_cell' if kind == 'force_move'
    return 'runner_skill' if kind == 'cooldown_reset'
    'runner'
  end

  # ── 진행 루프 (1초마다) ─────────────────────────────────────
  def tick!
    @mutex.synchronize do
      @sessions.each_value do |s|
        begin
          next unless s.active
          next if lobby?(s.id)
          was_active = true
          before = { phase: s.phase, round: s.round, actions: s.actions.dup, skill: s.creature[:current_skill].to_s, target: s.creature[:skill_target].to_s,
                     single: s.creature[:current_skill].to_s != '전체공격' && BattleBossPatterns.range_shape(s.creature) != '전체' && BattleBossPatterns.pattern_cells(s.creature).empty? }
          if s.phase == :prep && !s.announced
            @last_post_time = announce_prep_round(s, @runner_sheet, @runner_sheet, @last_post_time)
          end
          check_prep_completion(s, @creature_sheet)
          if s.phase == :announcing && !s.announced
            @last_post_time = announce_round(s, @runner_sheet, @creature_sheet, @runner_sheet, @last_post_time)
          end
          if s.phase == :boss_command && s.awaiting_boss && !s.announced
            @last_post_time = announce_boss_turn(s, @runner_sheet, @runner_sheet, @last_post_time)
          end
          @last_post_time, = settle_session_if_needed(s, @runner_sheet, @creature_sheet, @runner_sheet, @last_post_time, nil, nil)
          overlay_events!(s, before)
          announce_finish!(s) if was_active && !s.active
        rescue => e
          puts "[엔진 오류] #{e.class}: #{e.message}"
          puts e.backtrace.first(5)
          sheet_log(@creature_sheet, s.id, s.round, '오류', "#{e.class}: #{e.message}")
        end
      end
      WebState.sync_sessions(@sessions)
      snap = public_json
      key = snap.gsub(/"(now|updated_at)":\d+,?/, '')
      if key != @last_snapshot
        @last_snapshot = key
        bump!
      end
      @sessions.delete_if { |_id, s| s.finished? && (Time.now - s.start_time) > 3600 }
      @tokens.delete_if { |_t, (sid, _)| !@sessions.key?(sid) }
    end
  end

  # ── 관전자: 이름 + 응원 버튼 (채팅 없음) ─────────────────────
  CHEERS = { 'clap' => '박수', 'fire' => '힘내!', 'guard' => '버텨!', 'star' => '멋져요!', 'wow' => '조심!' }.freeze

  def clean_name(name)
    n = name.to_s.gsub(/[[:cntrl:]<>]/, '').strip
    raise '이름을 1~12자로 넣어 주세요.' if n.empty? || n.length > 12
    n
  end

  def watcher_hello!(name)
    n = clean_name(name)
    fresh = !@watchers.key?(n) || @watchers[n] < Time.now - 60
    @watchers[n] = Time.now
    bump! if fresh
    n
  end

  def watcher_names
    @watchers.delete_if { |_, t| t < Time.now - 70 }
    @watchers.keys.sort
  end

  def cheer!(battle_id, name, kind, ip)
    n = clean_name(name)
    raise '없는 응원입니다.' unless CHEERS.key?(kind.to_s)
    s = @sessions[battle_id.to_s]
    raise '진행 중인 전투가 아닙니다.' unless s && s.active
    k = "#{ip}|#{n}"
    raise '응원은 2초에 한 번씩 보낼 수 있어요.' if @cheer_last[k] && Time.now - @cheer_last[k] < 2
    @cheer_last[k] = Time.now
    @watchers[n] = Time.now
    c = @cheers[s.id]
    c['counts'][kind.to_s] += 1
    c['recent'] << { 'name' => n, 'kind' => kind.to_s, 'text' => CHEERS[kind.to_s], 'at' => Time.now.to_i }
    c['recent'].shift while c['recent'].size > 30
    bump!
  end

  # ── 채팅: 참여자와 진행자(관리자)만 보낼 수 있고, 모든 화면에서 보인다 ──
  def chat!(battle_id, name, role, text, key)
    s = @sessions[battle_id.to_s] or raise '전투를 찾지 못했습니다.'
    text = text.to_s.gsub(/[[:cntrl:]]/, ' ').strip
    raise '내용을 입력하세요.' if text.empty?
    raise '한 번에 200자까지 보낼 수 있어요.' if text.length > 200
    raise '조금 천천히 보내 주세요.' if @chat_last[key] && Time.now - @chat_last[key] < 1
    @chat_last[key] = Time.now
    @chats[s.id] << { 'name' => name.to_s, 'role' => role, 'text' => text, 'at' => Time.now.to_i, 'who' => key }
    @chats[s.id].shift while @chats[s.id].size > 200
    bump!
  end

  def player_chat!(token, text)
    s, name = player_for(token)
    raise '링크가 올바르지 않습니다.' unless s
    disp = runner_row(name).to_a[1].to_s
    chat!(s.id, disp.empty? ? name : disp, 'runner', text, "p:#{name}")
  end

  def admin_chat!(battle_id, text)
    chat!(battle_id, '진행자', 'admin', text, 'admin')
  end

  # ── 관리자 로그인: 비밀번호 → 브라우저 쿠키(12시간). 5번 틀리면 10분 잠금 ──
  ADMIN_TTL = 12 * 3600

  def admin_login!(password, ip)
    now = Time.now
    fails = @login_fails[ip].select! { |t| t > now - 600 } || @login_fails[ip]
    all = @login_fails.values.flatten.count { |t| t > now - 600 }
    raise '비밀번호를 여러 번 틀려서 10분 동안 잠겼습니다.' if fails.size >= 5 || all >= 30
    unless secure_eq(password.to_s.strip, admin_key.to_s.strip)
      fails << now
      raise "관리자 비밀번호가 틀렸습니다. (#{5 - fails.size}번 남음)"
    end
    @login_fails.delete(ip)
    token = SecureRandom.hex(24)
    @admin_sessions[token] = now + ADMIN_TTL
    token
  end

  def admin?(token)
    t = @admin_sessions[token.to_s]
    return false unless t && t > Time.now
    true
  end

  def admin_logout!(token)
    @admin_sessions.delete(token.to_s)
  end

  def change_password!(old, new_pw, keep_token)
    raise '지금 비밀번호가 틀렸습니다.' unless secure_eq(old.to_s, admin_key.to_s)
    new_pw = new_pw.to_s.strip
    raise '새 비밀번호는 6자 이상으로 해 주세요.' if new_pw.length < 6
    settings['admin_key'] = new_pw
    @store.save!
    @admin_sessions.select! { |k, _| k == keep_token }
  end

  def secure_eq(a, b)
    return false unless a.bytesize == b.bytesize
    a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
  end

  def admin_view
    @mutex.synchronize do
      {
        'tables' => tables,
        'runner_ids' => runner_ids,
        'creature_names' => creature_names,
        'boss_skills' => boss_skill_names,
        'kinds' => SkillCatalog::KINDS,
        'item_types' => ITEM_TYPES,
        'passives' => PASSIVES.transform_values { |v| { 'label' => v[2], 'desc' => v[3] } },
        'version' => @version,
        'battles' => @sessions.values.map do |s|
          {
            'id' => s.id,
            'active' => s.active,
            'phase' => lobby?(s.id) ? 'lobby' : s.phase.to_s,
            'ready' => @lobby[s.id].to_a,
            'round' => s.round,
            'auto' => s.auto_mode ? true : false,
            'awaiting_boss' => s.awaiting_boss ? true : false,
            'boss_skills' => boss_skill_list(s.creature[:name]).then { |l| l.empty? ? boss_skill_names : l },
            'creature' => s.creature[:name],
            'runners' => s.runner_names,
            'actions' => s.actions.transform_values { |a| "#{a[:type].to_s.sub('순간이동', '이동')}#{a[:target].to_s.empty? ? '' : '/' + a[:target].to_s}" },
            'tokens' => s.instance_variable_get(:@web_tokens) || {}
          }
        end
      }
    end
  end
end
