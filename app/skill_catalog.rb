# skill_catalog.rb
# encoding: UTF-8
#
# 러너 스킬을 data/raid.json 의 '스킬' 표에서 읽어 BattleSkills::SKILLS 를 다시 만든다.
# 계산은 스킬 "이름"이 아니라 "효과(kind)"로 이루어지므로, 이름을 바꾸거나 같은 효과의
# 새 스킬을 추가해도 기존 규칙 그대로 계산된다.

module SkillCatalog
  HEADER = %w[이름 분류 효과 사거리 쿨타임 1회성 배율 장거리배율 비율 수치 지속턴 최대대상 참여자표시].freeze

  # 효과 코드 → 화면에 보일 설명
  KINDS = {
    'attack' => '단일 공격 (마법능력×배율)',
    'attack_debuff' => '공격 + 시야차단',
    'confusion' => '혼란 공격 (2중첩 시 보스 행동 무효)',
    'rush' => '습격 (돌진 후 공격, 도착 칸 지정)',
    'area_attack' => '점유칸 수만큼 피해 (폭발)',
    'sacrifice_attack' => '자기 체력 소모 공격 (고육지책)',
    'heal' => '회복 (마법능력×비율)',
    'heal_area' => '사거리 안 전원 회복',
    'heal_fixed' => '고정량 회복 (수치)',
    'heal_fixed_self' => '자기 고정 회복 (흡수)',
    'heal_self_pure' => '자기 회복 (자가치유)',
    'atk_buff_area' => '사거리 안 전원 공격력 강화',
    'shield' => '보호막 (수치, 최대대상)',
    'sure_hit' => '대상 필중/크리티컬',
    'luck_buff' => '행운 강화 (수치, 지속턴)',
    'cooldown_reset' => '대상 쿨타임 초기화 (즉발)',
    'force_move' => '대상 이동 (행운부여)',
    'dur_guard' => '대상 내구도 강화 (방어, 비율)',
    'agi_buff_self' => '자기 민첩 + 수치 (회피)',
    'revenge' => '복수 (받은 피해 반사, 배율)',
    'cover' => '희생 (대신 맞기)',
    'dur_buff_area' => '사거리 안 전원 내구도 강화 (철벽)',
    'agi_buff_area' => '사거리 안 전원 민첩 + 수치 (주의분산)',
    'survive_once' => '필사즉생 (다인공격 흡수, 1회)',
    'teleport' => '1칸 이동 (가로·세로·대각선, 이름 고정)',
    'pass' => '관찰 / 턴 넘기기 (이름 고정)'
  }.freeze

  FIXED = { 'teleport' => '이동', 'pass' => '관찰' }.freeze
  BOSS_ONLY = %w[지정공격1인 지정공격다인 범위공격 전체공격].freeze
  AREA_KINDS = %w[heal_area atk_buff_area dur_buff_area agi_buff_area].freeze
  DEFAULT_VISIBLE = %w[공격 방어 회복 회피 이동 관찰].freeze

  ORIGINAL = BattleSkills::SKILLS

  module_function

  def default_rows
    rows = ORIGINAL.reject { |name, _| BOSS_ONLY.include?(name) }.map { |name, d| to_row(name, d, DEFAULT_VISIBLE.include?(name)) }
    rows << ['이동', '이동', 'teleport', '1칸', '0', '', '', '', '', '', '', '', 'O']
    rows << ['관찰', '대기', 'pass', '-', '0', '', '', '', '', '', '', '', 'O']
    [HEADER.dup] + rows
  end

  def to_row(name, d, visible)
    [name, d[:category].to_s, d[:kind].to_s, d[:range].to_s, d[:cooldown].to_s, d[:once] ? 'O' : '',
     d[:multiplier].to_s, d[:long_multiplier].to_s, d[:ratio].to_s, d[:value].to_s, d[:turns].to_s,
     d[:max_targets].to_s, visible ? 'O' : '']
  end

  def yes?(v)
    %w[o O y Y yes true TRUE 1 ✓ 예].include?(v.to_s.strip)
  end

  def num(v)
    t = v.to_s.strip
    return nil if t.empty?
    t.include?('.') ? t.to_f : t.to_i
  end

  # 표 → BattleSkills::SKILLS 해시
  def build(rows)
    out = {}
    Array(rows)[1..].to_a.each do |r|
      name = r[0].to_s.strip
      kind = r[2].to_s.strip
      next if name.empty? || FIXED.key?(kind) || !KINDS.key?(kind)
      d = { category: r[1].to_s.strip, range: r[3].to_s.strip, cooldown: num(r[4]) || 0, kind: kind.to_sym }
      d[:once] = true if yes?(r[5])
      { multiplier: 6, long_multiplier: 7, ratio: 8, value: 9, turns: 10, max_targets: 11 }.each do |key, i|
        v = num(r[i])
        d[key] = v unless v.nil?
      end
      # 원래 스킬에만 있던 세부값(디버프 종류 등)은 효과가 같으면 이어받는다
      base = ORIGINAL.values.find { |o| o[:kind] == d[:kind] }
      base.to_h.each { |k, v| d[k] = v unless d.key?(k) || %i[once cooldown range category].include?(k) }
      out[name] = d.freeze
    end
    ORIGINAL.each { |name, d| out[name] ||= d if BOSS_ONLY.include?(name) }
    out.freeze
  end

  def install!(rows)
    table = build(rows)
    BattleSkills.send(:remove_const, :SKILLS)
    BattleSkills.const_set(:SKILLS, table)
  end

  # 참여자 화면에 보일 스킬 (표 순서대로)
  def visible(rows)
    Array(rows)[1..].to_a.select { |r| yes?(r[12]) && !r[0].to_s.strip.empty? }.map do |r|
      kind = r[2].to_s.strip
      { name: FIXED[kind] || r[0].to_s.strip, kind: kind }
    end.select { |s| FIXED.key?(s[:kind]) || BattleSkills.get(s[:name]) }
  end

  # 러너 전용 스킬 (러너 표의 '스킬2' 칸에 쉼표로 적힌 이름들)
  def extra(rows, names)
    want = names.to_s.split(',').map(&:strip).reject(&:empty?)
    Array(rows)[1..].to_a.select { |r| want.include?(r[0].to_s.strip) }.map do |r|
      kind = r[2].to_s.strip
      { name: FIXED[kind] || r[0].to_s.strip, kind: kind }
    end.select { |s| FIXED.key?(s[:kind]) || BattleSkills.get(s[:name]) }
  end

  def validate!(rows)
    names = []
    Array(rows)[1..].to_a.each do |r|
      name = r[0].to_s.strip
      next if name.empty?
      raise "스킬 이름에는 [ ] / , 를 쓸 수 없습니다: #{name}" if name.match?(%r{[\[\]/,]})
      raise "같은 이름의 스킬이 두 개 있습니다: #{name}" if names.include?(name)
      raise "'#{name}'의 효과를 목록에서 골라 주세요." unless KINDS.key?(r[2].to_s.strip)
      raise "'#{name}'은(는) 보스 전용 스킬 이름이라 쓸 수 없습니다." if BOSS_ONLY.include?(name)
      names << name
    end
    rows.each { |r| r[0] = FIXED[r[2].to_s.strip] if FIXED.key?(r[2].to_s.strip) }
  end
end
