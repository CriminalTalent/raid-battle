# round_flow.rb
# encoding: UTF-8
#
# 라운드 진행 함수 모음 (준비 라운드, 크리쳐 차례 안내, 라운드 안내, 행동 접수, 정산).
# app/engine.rb 가 이 파일에서 함수만 골라 불러온다. 게시·기록·시트 같은 바깥 연결은
# app/engine.rb 가 웹용으로 정의한다. 승리 보상·패배 압수는 app/engine.rb 의 settle_credits! 가 한다.

def announce_prep_round(session, view_sheet, runner_sheet, last_post_time, sessions: nil)
  ctx = session.passive_ctx
  ctx[:positions] ||= {}

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  ctx[:prep_required] = state.select { |r| r[:hp].to_i > 0 }.map { |r| r[:name].to_s }
  session.mark_dead_runners(state.select { |r| r[:hp].to_i <= 0 }.map { |r| r[:name].to_s })
  WebState.update_runners(session, state)

  map_lines = BattleGrid.render([], session.creature)

  # 다른 팀(다른 세션)의 몹은 노출하지 않습니다. 본인 세션의 몹 상태는
  # 위 announcement에서 이미 별도로 표시됩니다.
  raid_overview = ''

  announcement = "#{session.runner_tags}\n\n" \
                 "[준비 라운드] #{session.creature[:name]}와의 전투!\n" \
                 "#{session.creature[:name]} 상태: #{view_sheet.health_bar(session.creature[:hp], session.creature[:max_hp])} (위치: #{session.creature[:pos]}, 크기: #{session.creature[:size] || '1x1'})\n\n" \
                 "#{raid_overview}" \
                 "점유칸: #{BattleGrid.occupied_cells_label(session.creature)}\n\n" \
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "DM 또는 멘션으로 시작 위치를 입력해주세요.\n\n" \
                 "형식: [좌표]\n" \
                 "입력 대기: 5분\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id'] && !response['partial']
    session.announced = true
    session.phase = :prep
    puts "[전투봇] [세션 #{session.id}] 준비 라운드 안내 송출"
  else
    session.announced = false
    session.phase = :prep
    puts "[전투봇] [세션 #{session.id}] 준비 라운드 안내 송출 실패#{response && response['partial'] ? ' (부분 게시)' : ''}"
  end
  new_time
end

def handle_prep_input(session, username, text, processed_set, processed_id, listener, global_set = nil, status_id = nil)
  processed_set.add(processed_id)

  sid = (status_id || processed_id).to_s
  return if global_set && global_set.include?(sid)

  m = text.to_s.match(/\[([A-Ga-g][1-8])\]/)
  return unless m

  global_set.add(sid) if global_set

  pos = m[1].upcase
  if BattleGrid.creature_cells(session.creature).include?(pos)
    listener.send_dm(username, "#{pos}은(는) #{session.creature[:name]}이(가) 점유한 칸입니다. 다른 좌표를 입력 해주세요.")
    return
  end

  (session.passive_ctx[:positions] ||= {})[username.to_s] = pos
  puts "[전투봇] [세션 #{session.id}] 시작 위치 등록: #{username} → #{pos}"
end

def check_prep_completion(session, creature_sheet = nil)
  return unless session.active && session.phase == :prep && session.announced

  ctx = session.passive_ctx
  required  = (ctx[:prep_required] || session.runner_names).map(&:to_s)
  positions = ctx[:positions] || {}

  all_set = required.any? && required.all? { |name| positions[name].to_s.match?(/\A[A-G][1-8]\z/) }
  timeout = (Time.now - session.start_time) >= ACTION_WAIT_SECONDS
  return unless all_set || timeout

  session.awaiting_boss = false
  session.phase = :announcing
  ctx[:boss_override] = { skill: '전체공격' }
  session.announced = false
  session.actions = {}
  session.processed_messages = {}
  session.start_time = Time.now
  puts "[전투봇] [세션 #{session.id}] 준비 라운드 완료 - #{session.round}라운드 시작 (크리쳐 행동: 전체공격 고정)"
  positions_text = positions.map { |k, v| "#{k}→#{v}" }.join(', ')
  sheet_log(creature_sheet, session.id, session.round, '준비 라운드 완료',
            "시작 위치: #{positions_text} / #{session.round}라운드 시작 (크리쳐 행동: 전체공격 고정)")
end

def announce_boss_turn(session, view_sheet, runner_sheet, last_post_time)
  ctx = session.passive_ctx
  positions = (ctx[:positions] ||= {})

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  begin
    base_stats = runner_sheet.read_base_stats
  rescue
    base_stats = []
  end
  state.each do |r|
    pos = positions[r[:name].to_s].to_s.upcase
    r[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
    stat = base_stats.find { |b| b[:name].to_s.casecmp?(r[:name].to_s) }
    label = stat ? stat[:display_name].to_s.strip : ''
    r[:display_name] = label.empty? ? r[:name].to_s : label
  end

  alive_for_map = state.select { |r| r[:hp].to_i > 0 }
  map_lines = BattleGrid.render(alive_for_map, session.creature)

  announcement = "#{session.runner_tags}\n\n" \
                 "[#{session.round}라운드] #{session.creature[:name]}와의 전투 - 크리쳐 턴\n" \
                 "#{session.creature[:name]} 상태: #{view_sheet.health_bar(session.creature[:hp], session.creature[:max_hp])} (위치: #{session.creature[:pos]}, 크기: #{session.creature[:size] || '1x1'} 방향: #{session.creature[:facing] || '하'})\n\n" \
                 "점유칸: #{BattleGrid.occupied_cells_label(session.creature)}\n\n" \
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "#{session.creature[:name]}이(가) 다음 행동을 준비하고 있습니다.\n" \
                 "운영 계정의 크리쳐 행동 입력 대기 중\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id'] && !response['partial']
    session.announced = true
    session.phase = :boss_command
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 크리쳐 턴 안내 송출"
  else
    session.announced = false
    session.phase = :boss_command
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 크리쳐 턴 안내 송출 실패#{response && response['partial'] ? ' (부분 게시)' : ''}"
  end
  new_time
end

def announce_round(session, view_sheet, creature_sheet, runner_sheet, last_post_time)
  ctx = session.passive_ctx
  positions = (ctx[:positions] ||= {})

  state = merge_runner_state(view_sheet, runner_sheet, session.runner_names, 'D3')
  begin
    base_stats = runner_sheet.read_base_stats
  rescue
    base_stats = []
  end
  state.each do |r|
    pos = positions[r[:name].to_s].to_s.upcase
    r[:pos] = pos if pos.match?(/\A[A-G][1-8]\z/)
    stat = base_stats.find { |b| b[:name].to_s.casecmp?(r[:name].to_s) }
    label = stat ? stat[:display_name].to_s.strip : ''
    r[:display_name] = label.empty? ? r[:name].to_s : label
  end
  session.mark_dead_runners(state.select { |r| r[:hp].to_i <= 0 }.map { |r| r[:name].to_s })

  refresh_creature_skill!(session.creature, creature_sheet)
  creature = session.creature

  override = ctx.delete(:boss_override)
  if override.is_a?(Hash)
    if override[:skill].to_s.strip != ''
      creature[:current_skill] = override[:skill].to_s.strip
      creature[:pattern]       = creature[:current_skill]
      apply_boss_skill_definition!(creature, creature_sheet)
      ctx[:prev_boss_skill] = creature[:current_skill]
    end
    if override[:cells].to_a.any?
      creature[:skill_range]   = override[:cells].join(',')
      creature[:pattern_cells] = override[:cells].join(',')
      creature[:skill_target]  = ''
    elsif override[:targets].to_a.any?
      mapped = override[:targets].map do |t|
        found = state.find do |r|
          r[:name].to_s == t ||
            r[:display_name].to_s == t ||
            r[:display_name].to_s.gsub(/\s+/, '') == t.gsub(/\s+/, '')
        end
        found ? found[:name].to_s : t
      end
      creature[:skill_target] = mapped.join(',')
    end
  end

  boss_preview = ''
  skill_name = BattleBossPatterns.pattern_name(creature)
  if !skill_name.empty? && skill_name != '-'
    whole = skill_name == '전체공격' ||
            BattleBossPatterns.range_shape(creature) == '전체' ||
            creature[:skill_range_default].to_s.strip == '전체'
    cells  = BattleBossPatterns.pattern_cells(creature)
    target = BattleBossPatterns.skill_target(creature)

    if !whole && cells.empty? && target.empty?
      alive = state.select { |r| r[:hp].to_i > 0 }
      picked = alive.sample([BattleBossPatterns.target_count(creature), 1].max)
      creature[:skill_target] = picked.map { |r| r[:name].to_s }.join(',')
      target = creature[:skill_target]
    end

    display_of = lambda do |id|
      found = state.find { |r| r[:name].to_s == id.to_s }
      found ? found[:display_name].to_s : id.to_s
    end

    label = if whole
              '전체'
            elsif cells.any?
              cells.join(', ')
            elsif !target.empty?
              target.split(',').map(&:strip).map { |t| display_of.call(t) }.join(', ')
            else
              ''
            end

    unless label.empty?
      power = BattleBossPatterns.pattern_damage(creature, BattleBossPatterns.pattern_multiplier(creature))
      boss_preview  = "공격 대상(범위): #{label}\n"
      boss_preview += "위력: #{power}\n" if power.to_i > 0 && BattleBossPatterns.skill_category(creature) != '디버프'
      boss_preview += "\n"
    end
  end

  # 크리쳐가 러너 전용 지원/방어 스킬(자가구원 등)을 쓰기로 확정된 경우엔
  # "공격 대상/위력" 형식이 아니라 스킬명만 안내한다.
  creature_skill_def = BattleSkills.get(creature[:current_skill].to_s.strip)
  if creature_skill_def && !BattleSkills.attack?(creature[:current_skill].to_s.strip)
    boss_preview = "#{creature[:name]}이(가) #{creature[:current_skill]}을(를) 사용합니다.\n\n"
  end

  WebState.update_runners(session, state)

  omen = creature[:omen].to_s.strip
  omen_block = omen.empty? ? '' : "#{omen}\n\n"

  alive_for_map = state.select { |r| r[:hp].to_i > 0 }
  map_lines = BattleGrid.render(alive_for_map, creature)

  creature_name = creature[:name].to_s.strip
  creature_name = '크리쳐이름' if creature_name.empty? || creature_name == '크리쳐'
  attack_lines = ["[스킬명/#{creature_name}]"]

  announcement = "#{session.runner_tags}\n\n" \
                 "[#{session.round}라운드] #{creature[:name]}와의 전투!\n\n" \
                 "#{omen_block}" \
                 "#{boss_preview}" \
                 "#{creature[:name]} 상태: #{view_sheet.health_bar(creature[:hp], creature[:max_hp])} (위치: #{creature[:pos]}, 크기: #{creature[:size] || '1x1'})\n\n" \
                 "전장\n\n" \
                 "#{map_lines.join("\n")}\n" \
                 "───────────────────\n" \
                 "DM 또는 멘션으로 행동을 입력해주세요.\n\n" \
                 "형식:\n" \
                 "공격: #{attack_lines.join("\n")}\n" \
                 "지원: [스킬명/아이디]\n" \
                 "방어: [스킬명/아이디]\n" \
                 "순간이동: [순간이동/좌표] (거리 제한 없음)\n" \
                 "아이템 사용: [물약이름/아이디] (ex [위겐웰드 물약/아이디], 소지품에 있을경우)\n" \
                 "입력 대기: 5분\n" \
                 "───────────────────"

  response, new_time = post_session_thread(session, announcement, last_post_time)
  if response && response['id'] && !response['partial']
    session.announced = true
    session.phase = :battle
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 안내 송출"
  else
    session.announced = false
    session.phase = :announcing
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 안내 송출 실패#{response && response['partial'] ? ' (부분 게시)' : ''}"
  end
  new_time
end

def process_action_for_session(session, username, text, processed_set, processed_id, runner_sheet, view_sheet, listener, processed_action_status_ids = nil, status_id = nil)
  status_id ||= processed_id
  if processed_action_status_ids && processed_action_status_ids.include?(status_id.to_s)
    processed_set.add(processed_id)
    return false
  end

  before = session.actions.size

  record_battle_action(
    username,
    text,
    session.actions,
    session.processed_messages,
    processed_set,
    processed_id,
    session.runner_names,
    view_sheet,
    runner_sheet,
    session.creature,
    listener,
    session.passive_ctx
  )

  changed = session.actions.size > before
  processed_action_status_ids.add(status_id.to_s) if processed_action_status_ids
  changed
end

def announce_manual_battle_end!(target, scout_sheet, scout_grid_sheet, last_post_time)
  response, new_time = post_session_thread(target, "#{target.runner_tags}\n\n[전투 중단]", last_post_time)
  last_post_time = new_time

  last_post_time
end

# 라운드 정산 결과 안내가 전부 게시될 때까지 재시도한다.
# (부분 게시/게시 실패 시 라운드가 소리 없이 그냥 넘어가던 문제 수정)
def flush_pending_result!(session, scout_sheet, scout_grid_sheet, creature_sheet, last_post_time)
  ctx = session.passive_ctx
  pending = ctx[:pending_result]
  return [last_post_time, false] unless pending

  while pending[:parts].any?
    part = pending[:parts].first
    response, new_time = post_session_thread(session, part, last_post_time)
    last_post_time = new_time

    if response && response['id'] && !response['partial']
      pending[:parts].shift
    else
      puts "[전투봇] [세션 #{session.id}] #{pending[:round]}라운드 결과 안내 미발송 (남은 #{pending[:parts].size}개) — 재시도 예정"
      return [last_post_time, false]
    end
  end

  ctx.delete(:pending_result)
  session.mark_dead_runners(pending[:dead])

  if pending[:escaped]
    session.active = false
    session.auto_next_round_timer = nil
    session.awaiting_boss = false
    puts "[전투봇] [세션 #{session.id}] 전투 이탈 성공"
    sheet_log(creature_sheet, session.id, pending[:round], '전투 이탈', '이탈 성공')

    return [last_post_time, true]
  end

  if pending[:creature_dead] || pending[:all_runners_dead]
    session.active = false
    session.auto_next_round_timer = nil
    session.awaiting_boss = false
    puts "[전투봇] [세션 #{session.id}] 전투 종결 (#{pending[:creature_dead] ? '승리' : '패배'})"
    sheet_log(creature_sheet, session.id, pending[:round], '전투 종결', pending[:creature_dead] ? '크리쳐 격파 - 승리' : '전원 전투 불가 - 패배')

    [last_post_time, true]
  else
    session.round += 1
    session.phase = :boss_command
    session.awaiting_boss = true
    session.announced = false
    session.actions = {}
    session.processed_messages = {}
    session.start_time = Time.now
    session.auto_next_round_timer = nil
    # 필사즉생 과잉피해 잠금은 정확히 1라운드만 적용되어야 한다. 플레이어가
    # 아무 메시지도 보내지 않고 라운드가 타임아웃되면 record_battle_action의
    # 소비 로직을 못 거치므로 잠금이 계속 이월되는 문제가 있었다. 새 라운드
    # 시작 시점에 무조건 자동으로 "행동불가" 처리하고 잠금을 해제해 이월을 막는다.
    if ctx && ctx[:action_locked] && ctx[:action_locked].any?
      puts "[전투봇] [세션 #{session.id}] action_locked 강제소비 실행 → #{ctx[:action_locked].keys.join(', ')} (#{session.round}라운드)"
      ctx[:action_locked].keys.each do |locked_name|
        session.actions[locked_name] = { type: '행동불가', target: '' }
        session.processed_messages[locked_name] = true
      end
      ctx[:action_locked] = {}
    end

    if session.auto_mode
      # '현재스킬'이 채워져 있으면 자동 모드여도 무작위 선택 대신 그 값을
      # 그대로 고정 사용한다. 세션 시작 시 캐시된 값이 아니라 매 라운드
      # 시트에서 새로 읽어, 전투 도중 운영진이 값을 바꾸면 다음 라운드부터
      # 바로 반영되도록 한다.
      fresh_creature = creature_from_stats_sheet_by_name(creature_sheet, session.creature[:name])
      fixed_skill = fresh_creature ? fresh_creature[:current_skill].to_s.strip : ''
      auto_skill = fixed_skill.empty? ? select_auto_skill(session.creature, creature_sheet, session.passive_ctx) : fixed_skill
      if auto_skill
        session.passive_ctx[:boss_override] = { skill: auto_skill }
        session.awaiting_boss = false
        session.phase = :announcing
      end
    end

    puts "[전투봇] [세션 #{session.id}] #{pending[:round]}라운드 정산 완료 - #{session.round}라운드 크리쳐행동커맨드 대기"
    [last_post_time, false]
  end
end

def settle_session_if_needed(session, runner_sheet, creature_sheet, view_sheet, last_post_time, scout_sheet = nil, scout_grid_sheet = nil)
  return [last_post_time, false] unless session.active

  ctx = session.passive_ctx

  # 이전 라운드 결과 안내가 아직 완전히 게시되지 못했다면, 새 라운드를
  # 정산하기 전에 먼저 그 결과부터 끝까지 게시되도록 재시도한다.
  if ctx[:pending_result]
    return flush_pending_result!(session, scout_sheet, scout_grid_sheet, creature_sheet, last_post_time)
  end

  return [last_post_time, false] unless session.phase == :battle

  required = session.required_actions
  round_done = required > 0 && session.actions.size >= required
  round_timeout = (Time.now - session.start_time) >= ACTION_WAIT_SECONDS
  return [last_post_time, false] unless round_done || round_timeout

  session.passive_ctx[:round] = session.round.to_i
  begin
    log, runner_state = settle_round(
      session.actions,
      session.runner_names,
      runner_sheet,
      creature_sheet,
      view_sheet,
      session.creature,
      session.passive_ctx
    )
  rescue => e
    puts "[전투봇] [세션 #{session.id}] #{session.round}라운드 정산 실패: #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
    sheet_log(creature_sheet, session.id, session.round, '정산 실패',
              "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}\n크리쳐행동커맨드 입력 시 다음 라운드로 진행됩니다.")
    session.round += 1
    session.phase = :boss_command
    session.awaiting_boss = true
    session.announced = false
    session.actions = {}
    session.processed_messages = {}
    session.start_time = Time.now
    session.auto_next_round_timer = nil
    # 필사즉생 과잉피해 잠금은 정확히 1라운드만 적용되어야 한다. 플레이어가
    # 아무 메시지도 보내지 않고 라운드가 타임아웃되면 record_battle_action의
    # 소비 로직을 못 거치므로 잠금이 계속 이월되는 문제가 있었다. 새 라운드
    # 시작 시점에 무조건 자동으로 "행동불가" 처리하고 잠금을 해제해 이월을 막는다.
    if ctx && ctx[:action_locked] && ctx[:action_locked].any?
      puts "[전투봇] [세션 #{session.id}] action_locked 강제소비 실행 → #{ctx[:action_locked].keys.join(', ')} (#{session.round}라운드)"
      ctx[:action_locked].keys.each do |locked_name|
        session.actions[locked_name] = { type: '행동불가', target: '' }
        session.processed_messages[locked_name] = true
      end
      ctx[:action_locked] = {}
    end
    begin
      response, new_time = post_session_thread(session, "#{session.runner_tags}\n\n[안내] 라운드 정산 중 오류가 발생했습니다. 운영 계정이 크리쳐 행동을 입력하면 다음 라운드로 진행됩니다.", last_post_time)
      last_post_time = new_time
    rescue => post_err
      puts "[전투봇] [세션 #{session.id}] 정산 실패 안내 송출 실패: #{post_err.class}: #{post_err.message}"
    end
    return [last_post_time, false]
  end

  WebState.update_runners(session, runner_state)
  BattleItems.consume_all!(ctx)

  if ctx[:escaped_by]
    escaped_name = ctx.delete(:escaped_by)
    escaped_state = runner_state.find { |r| r[:name].to_s == escaped_name.to_s }
    escaped_label = escaped_state && !escaped_state[:display_name].to_s.strip.empty? ? escaped_state[:display_name] : escaped_name
    escape_text = "#{session.runner_tags}\n\n[#{session.round}라운드] 전투 이탈\n\n#{Array(log).join("\n")}\n\n#{escaped_label}의 이탈 성공 — 전투에서 벗어났습니다."
    sheet_log(creature_sheet, session.id, session.round, '이탈 성공', "#{escaped_label} 이탈 성공\n\n#{Array(log).join("\n")}")
    ctx[:pending_result] = {
      parts: [escape_text],
      round: session.round,
      dead: [],
      creature_dead: false,
      all_runners_dead: false,
      escaped: true
    }
    session.phase = :settling
    return flush_pending_result!(session, scout_sheet, scout_grid_sheet, creature_sheet, last_post_time)
  end

  result = build_result_text(
    session.runner_tags,
    session.round,
    session.creature,
    session.actions,
    session.runner_names,
    log,
    runner_state,
    view_sheet,
    timeout: round_timeout && !round_done
  )

  dead = runner_state.select { |r| session.runner_names.include?(r[:name].to_s) && r[:hp].to_i <= 0 }.map { |r| r[:name].to_s }
  creature_dead = session.creature[:hp].to_i <= 0
  all_runners_dead = runner_state.none? { |r| session.runner_names.include?(r[:name]) && r[:hp].to_i > 0 }

  actions_text = session.actions.map { |name, act| "#{name}: [#{act[:type]}/#{act[:target]}]" }.join(' / ')
  sheet_log(creature_sheet, session.id, session.round, '정산',
            "행동: #{actions_text.empty? ? '없음' : actions_text}\n\n#{Array(log).join("\n")}")

  # 정산은 끝났지만 결과 안내는 전부 게시될 때까지 확정하지 않는다.
  # (게시 실패/부분 게시 시에도 라운드가 그냥 넘어가던 문제 수정)
  ctx[:pending_result] = {
    parts: Array(result),
    round: session.round,
    dead: dead,
    creature_dead: creature_dead,
    all_runners_dead: all_runners_dead
  }
  session.phase = :settling

  flush_pending_result!(session, scout_sheet, scout_grid_sheet, creature_sheet, last_post_time)
end

# 크리쳐스킬 탭(A=스킬명, D=쿨타임)에서, 매 라운드 "지금 쿨타임이 돌아온
# 스킬" 전부를 후보로 모아 그중 무작위로 하나를 선택한다. 시트에 적힌
# 순서는 참고하지 않는다. 선택된 스킬의 쿨타임은 여기서 세팅하지 않고,
# 실제로 정산 단계에서 지원/방어 스킬로 실행될 때 cooldown_gate!가 러너와
# 동일한 방식으로 세팅한다. 전부 쿨타임 중이면 어쩔 수 없이 전체 목록에서
# 무작위로 선택한다(빈 라운드 방지).
def select_auto_skill(creature, creature_sheet, ctx = nil)
  return nil unless creature && creature_sheet
  begin
    rows = boss_skill_rows(creature_sheet)
    all_skills = rows.map { |r| [r[0].to_s.strip, r[3].to_s.strip.to_i] }.reject { |name, _| name.empty? }
    return nil if all_skills.empty?

    if ctx.is_a?(Hash)
      cooldowns = (ctx[:cooldowns] ||= Hash.new { |h, k| h[k] = {} })[CREATURE_COOLDOWN_KEY]
      # 시트에 적힌 순서는 무시하고, 매 라운드 "지금 쿨타임이 돌아온 스킬"
      # 전부를 후보로 모아서 그중 무작위로 하나를 뽑는다. 전부 쿨타임 중이면
      # 어쩔 수 없이 전체 목록에서 무작위로 뽑는다(빈 라운드 방지).
      # 쿨타임 세팅 자체는 여기서 하지 않는다 — 실제로 이 스킬이 정산
      # 단계에서 지원/방어 스킬로 실행될 때 cooldown_gate!가 러너와 동일한
      # 방식으로 세팅한다.
      ready = all_skills.reject { |name, _| cooldowns[name].to_i > 0 }
      ready = all_skills if ready.empty?
      ready.sample.first
    else
      all_skills.sample.first
    end
  rescue => e
    puts "[select_auto_skill 오류] #{e.class}: #{e.message}"
    nil
  end
end
