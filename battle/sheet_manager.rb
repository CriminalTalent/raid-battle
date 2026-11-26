# sheet_manager.rb
# encoding: UTF-8
#
# 러너·크리쳐 표를 읽고 쓰는 기본 클래스.
# 실제 저장(read / write / append)은 app/local_sheet.rb 의 LocalSheet 가 data/raid.json 으로 한다.
# 이 파일에는 표의 칸 배치(어느 칸이 어떤 스탯인지)와 그 해석만 있다.

class SheetManager
  BATTLE_LOG_SHEET = '전투로그'.freeze

  # ──────────────────────────────────────────────
  # 기본 I/O (LocalSheet 가 덮어쓴다)
  # ──────────────────────────────────────────────

  def read(_range)
    []
  end

  def write(_range, _values)
    false
  end

  def write_raw(range, values)
    write(range, values)
  end

  def append(_range, _values)
    false
  end

  def append_battle_log(row)
    append("#{BATTLE_LOG_SHEET}!A:E", row)
  end

  # ──────────────────────────────────────────────
  # 실행 탭
  # A2 = 전투 켜기/끄기 체크박스
  # B2 = 공개 범위 체크박스
  # ──────────────────────────────────────────────

  def read_bot_on
    rows = read("'실행'!A2")
    return false if rows.empty? || rows[0].nil?
    truthy?(rows[0][0])
  end

  def read_bot_on_or_nil
    read_bot_on
  end

  def read_visibility
    rows = read("'실행'!B2")
    return 'direct' if rows.empty? || rows[0].nil? || rows[0][0].to_s.strip.empty?
    truthy?(rows[0][0]) ? 'public' : 'direct'
  end

  def read_auto_mode
    rows = read("'실행'!C2")
    return false if rows.empty? || rows[0].nil?
    truthy?(rows[0][0])
  end

  def update_position(runner_name, pos)
    return false unless pos.to_s.match?(/\A[A-G][1-8]\z/)
    begin
      rows = read_range('D3', 'A:Z')
      return false if rows.empty?
      headers = header_map(rows[0])
      pos_col = header_col(headers, '위치', 'B')
      row_idx = rows.find_index { |row| row[1].to_s.strip == runner_name.to_s.strip }
      return false unless row_idx
      write_range('D3', "#{pos_col}#{row_idx + 1}", [[pos]])
      true
    rescue => e
      puts "[update_position 오류] #{e.class}: #{e.message}"
      false
    end
  end

  # ──────────────────────────────────────────────
  # 크리쳐 활성화 정보
  # ──────────────────────────────────────────────

  def read_creature_config
    # 크리쳐 탭은 사용하지 않습니다. 크리쳐는 스탯 탭의 활성 행으로만 결정합니다.
    nil
  end

  # ──────────────────────────────────────────────
  # 러너 스탯
  #
  # 자동봇 시트 / 스탯 탭 구조:
  # A ID
  # B 이름
  # C 팀
  # D 패시브선택
  # E 건강 (현재체력)
  # F 내구도
  # G 마법능력
  # H 민첩
  # I 기술
  # J 행운
  # K 최대건강 (최대체력의 유일한 출처)
  # L 스킬2
  # M facing
  #
  # E열 건강은 전투 중 현재 체력으로 갱신합니다.
  # 최대체력은 항상 K열(최대건강)에서 읽습니다 (E열로 대체하지 않음).
  #
  # read_base_stats는 한 라운드 처리(안내/크리쳐행동커맨드 파싱/정산) 중
  # 여러 지점에서 각각 독립적으로 호출되어 '스탯'!A2:M100 읽기가 짧은
  # 간격에 중복 발생하는 게 확인되어, 짧은 TTL 캐시를 추가했습니다.
  # HP(E열)는 라운드 중 세션 메모리(ctx) 상태를 기준으로 판정하므로,
  # 이 캐시가 몇 초 지연되어도 실제 판정 결과에는 영향이 없습니다.
  # ──────────────────────────────────────────────

  def read_base_stats
    now = Time.now
    if @base_stats_cache.nil? || @base_stats_cache_at.nil? || (now - @base_stats_cache_at) > 5
      rows = read("'스탯'!A2:M100")

      @base_stats_cache = rows.map do |row|
        id = row[0].to_s.strip
        next if id.empty?

        # E열이 비어있거나 숫자가 아니면 기본 50, "0"이면 전투불가(0) 그대로 유지
        hp_raw = row[4].to_s.strip
        hp = hp_raw.match?(/\A-?\d+\z/) ? [hp_raw.to_i, 0].max : 50

        # K열(최대건강)이 최대체력의 유일한 출처. 비어있거나 0 이하면 현재체력으로 대체.
        max_hp_raw = row[10].to_s.strip
        max_hp = max_hp_raw.match?(/\A-?\d+\z/) ? max_hp_raw.to_i : 0
        max_hp = hp if max_hp <= 0

        {
          name:         id,
          id:           id,
          display_name: row[1].to_s.strip,
          house:        row[2].to_s.strip,
          passive:      row[3].to_s.strip,
          hp:           hp,
          max_hp:       max_hp,
          dur:          row[5].to_i,
          atk:          row[6].to_i,
          agi:          row[7].to_i,
          tec:          row[8].to_i,
          luck:         row[9].to_i,
          skill2:       row[11].to_s.strip,
          facing:       row[12].to_s.strip.empty? ? '하' : row[12].to_s.strip
        }
      end.compact

      @base_stats_cache_at = now
    end

    @base_stats_cache
  rescue => e
    puts "[read_base_stats 오류] #{e.message}"
    @base_stats_cache || []
  end

  # HP를 시트에 실제로 반영한 직후에는 캐시를 즉시 무효화해,
  # 그다음 read_base_stats 호출이 방금 쓴 값을 곧바로 반영하도록 합니다.
  def invalidate_base_stats_cache!
    @base_stats_cache = nil
    @base_stats_cache_at = nil
  end

  # 크리쳐 스탯 탭 실제 컬럼 순서 (2026-08-13 확정, main.rb의 read_base_stats가
  # 읽는 러너용 '스탯' 탭과는 다른 스프레드시트/다른 배치이므로 절대 혼동 금지):
  # A=활성 B=이름 C=위치 D=크기 E=현재스킬 F=건강 G=내구도 H=마법능력 I=민첩 J=기술 K=행운 L=비고 M=보상골드
  # (별도 '최대건강' 컬럼 없음 — 크리쳐는 F열 건강 값을 그대로 최대건강으로도 사용)
  def read_creature_stats(creature_name)
    creature_name = creature_name.to_s.strip
    return nil if creature_name.empty?

    rows = read("'스탯'!A2:M100")

    row = rows.find do |r|
      r[1].to_s.strip == creature_name
    end

    unless row
      puts "[read_creature_stats] 스탯 탭에서 #{creature_name} 을(를) 찾지 못했습니다. 기본값 사용"
      return default_creature_stats(creature_name)
    end

    hp_raw = row[5].to_s.strip
    hp = hp_raw.match?(/\A-?\d+\z/) ? hp_raw.to_i : 200
    hp = 200 if hp <= 0

    pos_raw = row[2].to_s.strip.upcase
    pos = pos_raw.match?(/\A[A-G][1-8]\z/) ? pos_raw : (extract_position(row) || 'D4')

    {
      name:          creature_name,
      hp:            hp,
      max_hp:        hp,
      dur:           row[6].to_i,
      atk:           row[7].to_i,
      agi:           row[8].to_i,
      tec:           row[9].to_i,
      luck:          row[10].to_i,
      current_skill: row[4].to_s.strip,
      pos:           pos,
      status:        ''
    }
  rescue => e
    puts "[read_creature_stats 오류] #{e.message}"
    default_creature_stats(creature_name)
  end

  def default_creature_stats(name)
    {
      name:          name,
      hp:            200,
      max_hp:        200,
      dur:           10,
      atk:           10,
      agi:           0,
      tec:           0,
      luck:          0,
      current_skill: '',
      pos:           'D4',
      status:        ''
    }
  end

  # ──────────────────────────────────────────────
  # 러너 상태
  #
  # 더 이상 러너현황/맵현황 탭을 쓰지 않습니다.
  # 자동봇 시트 스탯 탭의 E열 건강을 현재 체력으로 읽고/씁니다.
  # 위치는 별도 위치봇/현황 탭이 없으면 기본 D3으로 시작합니다.
  # ──────────────────────────────────────────────

  def read_runner_state
    read_base_stats.map do |stat|
      {
        name:    stat[:name],
        pos:     'D3',
        hp:      stat[:hp].to_i,
        max_hp:  stat[:max_hp].to_i,
        status:  '',
        facing:  stat[:facing].to_s.strip.empty? ? '하' : stat[:facing]
      }
    end
  rescue => e
    puts "[read_runner_state 오류] #{e.message}"
    []
  end

  def update_runner_state(states)
    rows = read("'스탯'!A2:M100")
    return true if rows.empty?

    hp_by_id = states.to_a.each_with_object({}) do |state, h|
      id = state[:name].to_s.strip
      h[id] = state[:hp].to_i unless id.empty?
    end

    values = rows.map do |row|
      id = row[0].to_s.strip
      if hp_by_id.key?(id)
        [hp_by_id[id]]
      else
        [row[4]]
      end
    end

    result = write("'스탯'!E2:E#{rows.size + 1}", values)
    invalidate_base_stats_cache!
    result
  rescue => e
    puts "[update_runner_state 오류] #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # 크리쳐 현황 출력용
  # 현황 탭 2행에 기록: A=이름 / B=위치 / C=HP / D=최대HP
  # E=내구 / F=마법능력 / G=민첩 / H=기술 / I=행운 / J=상태
  # ──────────────────────────────────────────────

  def update_creature_state(creature)
    row = [[
      creature[:name],
      creature[:pos],
      creature[:hp],
      creature[:max_hp],
      creature[:dur],
      creature[:atk],
      creature[:agi],
      creature[:tec],
      creature[:luck],
      creature[:status].to_s
    ]]

    write("'현황'!A2:J2", row)
  rescue => e
    puts "[update_creature_state 오류] #{e.message}"
    false
  end

  # ──────────────────────────────────────────────
  # HP 바
  # ──────────────────────────────────────────────

  def health_bar(hp, max_hp)
    hp = hp.to_i
    max_hp = max_hp.to_i
    max_hp = 1 if max_hp <= 0

    filled = ((hp.to_f / max_hp) * 10).round
    filled = [[filled, 0].max, 10].min

    empty = 10 - filled
    "█" * filled + "░" * empty + " #{hp}/#{max_hp}"
  end

  private

  def truthy?(value)
    value == true ||
      value.to_s.strip.upcase == 'TRUE' ||
      value.to_s.strip == '1' ||
      value.to_s.strip.upcase == 'ON' ||
      value.to_s.strip == '✓' ||
      value.to_s.strip == '✔'
  end

  def numeric?(value)
    value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
  end

  def stat_value(row, primary_idx, fallback_idx, default_value)
    primary = row[primary_idx].to_i
    return primary if primary != 0

    fallback = row[fallback_idx].to_i
    return fallback if fallback != 0

    default_value
  end

  def extract_position(row)
    row.each do |cell|
      text = cell.to_s.strip.upcase
      return text if text.match?(/\A[A-G][1-8]\z/)
    end
    nil
  end
end
