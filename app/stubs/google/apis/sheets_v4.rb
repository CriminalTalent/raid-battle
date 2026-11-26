# 구글 시트 라이브러리 대체용 빈 정의 (로컬 실행에서는 구글에 연결하지 않음)
module Google
  module Apis
    class Error < StandardError; end
    class RateLimitError < Error; end
    class ServerError < Error; end
    class TransmissionError < Error; end
    module SheetsV4
      class SheetsService; end
      class ValueRange; end
    end
  end
end
