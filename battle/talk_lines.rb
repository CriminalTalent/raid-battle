# talk_lines.rb
# encoding: UTF-8
#
# [말걸기] 성공 시 보여줄 크리쳐별 우호적 대사 목록.
# 매핑에 없는 크리쳐는 GENERIC 목록에서 랜덤으로 고른다.
# 크리쳐 이름 => [대사, ...] 형태로 추가한다.

module TalkLines
  LINES = {}.freeze

  GENERIC = [
    '…뭐, 오늘은 이만하지.',
    '알겠어, 알겠다고. 가.',
    '흥, 봐주는 거다.'
  ].freeze

  module_function

  def success_line(creature_name)
    pool = LINES[creature_name.to_s.strip] || GENERIC
    pool.sample
  end
end
