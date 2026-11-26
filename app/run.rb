# run.rb — 레이드 웹앱 실행: ruby app/run.rb
# encoding: UTF-8
$stdout.sync = true
Encoding.default_external = 'UTF-8'
require_relative 'server'

# 내 PC: 기본값 그대로 (127.0.0.1:4567)
# 서버(Render·Railway·Docker 등): PORT 를 주면 0.0.0.0 으로 열린다.
#   RAID_DATA_DIR       데이터(raid.json, 이미지)를 둘 폴더 — 서버의 영구 디스크 경로
#   RAID_ADMIN_PASSWORD 관리자 비밀번호 (주면 켤 때마다 이 값으로 맞춘다)
port = (ENV['PORT'] || ENV['RAID_PORT'] || '4567').to_i
host = ENV['RAID_HOST'] || (ENV['PORT'] ? '0.0.0.0' : '127.0.0.1')
engine = RaidEngine.new(File.join(RAID_DATA_DIR, 'raid.json'))
unless ENV['RAID_ADMIN_PASSWORD'].to_s.strip.empty?
  engine.settings['admin_key'] = ENV['RAID_ADMIN_PASSWORD'].strip
  engine.store.save!
end

puts ''
puts '=========================================='
puts ' 레이드 전투 웹앱이 켜졌습니다'
puts "  관리자 : http://localhost:#{port}/admin"
puts "  관전자 : http://localhost:#{port}/watch"
puts ENV['RAID_ADMIN_PASSWORD'].to_s.strip.empty? ? "  관리자 비밀번호 : #{engine.admin_key}" : '  관리자 비밀번호 : RAID_ADMIN_PASSWORD 값'
puts '  끄려면 이 창을 닫거나 Ctrl+C'
puts '=========================================='
puts ''
RaidServer.new(engine, host: host, port: port).run
