# server.rb
# encoding: UTF-8
#
# 표준 라이브러리만 쓰는 작은 웹서버. 관리자/참여자/관전자 페이지와 API 제공.

require 'socket'
require 'uri'
require 'digest'
require 'fileutils'
require_relative 'engine'

class RaidServer
  PUBLIC = File.join(__dir__, 'public')
  IMG_DIR = File.join(RAID_DATA_DIR, 'img')
  IMG_TYPES = { 'jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp', 'gif' => 'image/gif' }.freeze
  PAGES = {
    '/' => 'index.html',
    '/admin' => 'admin.html',
    '/play' => 'play.html',
    '/watch' => 'watch.html'
  }.freeze

  def initialize(engine, host:, port:)
    @engine = engine
    @host = host
    @port = port
  end

  def run
    server = TCPServer.new(@host, @port)
    Thread.new do
      loop do
        @engine.tick!
        sleep 1
      end
    end
    loop do
      client = server.accept
      Thread.new(client) { |c| handle(c) }
    end
  end

  private

  def handle(client)
    request_line = client.gets.to_s
    method, target, = request_line.split(' ')
    headers = {}
    while (line = client.gets) && !["\r\n", "\n"].include?(line)
      k, v = line.split(':', 2)
      headers[k.to_s.strip.downcase] = v.to_s.strip
    end
    body = ''
    len = headers['content-length'].to_i
    body = client.read(len).to_s.force_encoding('UTF-8') if len.positive? && len < 3_000_000
    path, query = target.to_s.split('?', 2)
    params = URI.decode_www_form(query.to_s).to_h rescue {}
    path = path.chomp('/') if path.length > 1
    # share.bat(클라우드플레어) 로 들어오면 실제 접속자 주소는 이 헤더에 있다
    fwd = headers['cf-connecting-ip'].to_s
    fwd = headers['x-forwarded-for'].to_s.split(',').last.to_s.strip if fwd.empty?
    Thread.current[:ip] = fwd.empty? ? (client.peeraddr[3] rescue '?') : fwd
    Thread.current[:set_cookie] = nil

    status, type, out = route(method, path, params, headers, body)
    respond(client, status, type, out)
  rescue => e
    puts "[웹 오류] #{e.class}: #{e.message}"
    respond(client, 500, 'application/json', JSON.generate('error' => '서버 오류가 났습니다.')) rescue nil
  ensure
    client.close rescue nil
  end

  def json(obj, status = 200)
    [status, 'application/json; charset=utf-8', JSON.generate(obj)]
  end

  def route(method, path, params, headers, body)
    # 참여자: /p/<개인 링크>, 관전자: /w/<전투 번호>, 관리자: /admin
    if method == 'GET' && path.match?(%r{\A/p/[A-Za-z0-9_-]+\z})
      return [200, 'text/html; charset=utf-8', File.read(File.join(PUBLIC, 'play.html'), encoding: 'UTF-8')]
    end
    if method == 'GET' && path.match?(%r{\A/w/[A-Za-z0-9]+\z})
      return [200, 'text/html; charset=utf-8', File.read(File.join(PUBLIC, 'watch.html'), encoding: 'UTF-8')]
    end
    if method == 'GET' && (m = path.match(%r{\A/img/([a-f0-9]{16,64}\.(jpg|png|webp|gif))\z}))
      file = File.join(IMG_DIR, m[1])
      return [200, IMG_TYPES[m[2]], File.binread(file)] if File.exist?(file)
    end

    if method == 'GET' && PAGES[path]
      file = PAGES[path].start_with?('/') ? PAGES[path] : File.join(PUBLIC, PAGES[path])
      return [200, 'text/html; charset=utf-8', File.read(file, encoding: 'UTF-8')]
    end

    if method == 'GET' && (m = path.match(%r{\A/assets/([a-z0-9_-]+\.(js|css))\z}))
      file = File.join(PUBLIC, 'assets', m[1])
      type = m[2] == 'js' ? 'application/javascript; charset=utf-8' : 'text/css; charset=utf-8'
      return [200, type, File.read(file, encoding: 'UTF-8')] if File.exist?(file)
    end

    data = body.to_s.empty? ? {} : (JSON.parse(body) rescue {})

    case [method, path]
    when ['GET', '/api/battles']
      return [200, 'application/json; charset=utf-8', @engine.mutex.synchronize { @engine.public_json }]
    when ['GET', '/api/wait']
      return json('v' => @engine.wait_change(params['v'].to_i, 20))
    when ['GET', '/api/play']
      view = @engine.mutex.synchronize { @engine.player_view(params['t']) }
      return json({ 'error' => '링크가 올바르지 않거나 끝난 전투입니다.' }, 404) unless view
      return json(view)
    when ['POST', '/api/play']
      notice = @engine.mutex.synchronize { @engine.player_submit!(data['t'], data['command'].to_s) }
      @engine.bump!
      return json('ok' => notice.nil?, 'notice' => notice)
    when ['POST', '/api/ready']
      @engine.mutex.synchronize { @engine.player_ready!(data['t'], data['on'] != false) }
      return json('ok' => true)
    when ['POST', '/api/chat']
      @engine.mutex.synchronize { @engine.player_chat!(data['t'], data['text']) }
      return json('ok' => true)
    when ['POST', '/api/watch/hello']
      return json('name' => @engine.mutex.synchronize { @engine.watcher_hello!(data['name']) })
    when ['POST', '/api/cheer']
      @engine.mutex.synchronize { @engine.cheer!(data['id'], data['name'], data['kind'], Thread.current[:ip]) }
      return json('ok' => true)
    when ['POST', '/api/login']
      token = @engine.mutex.synchronize { @engine.admin_login!(data['password'], Thread.current[:ip]) }
      Thread.current[:set_cookie] = ["raid_admin=#{token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=#{RaidEngine::ADMIN_TTL}",
                     "raid_is_admin=1; Path=/; SameSite=Strict; Max-Age=#{RaidEngine::ADMIN_TTL}"]
      return json('ok' => true)
    when ['POST', '/api/logout']
      @engine.mutex.synchronize { @engine.admin_logout!(cookie(headers, 'raid_admin')) }
      Thread.current[:set_cookie] = ['raid_admin=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0', 'raid_is_admin=; Path=/; SameSite=Strict; Max-Age=0']
      return json('ok' => true)
    end

    if path.start_with?('/api/admin')
      unless @engine.mutex.synchronize { @engine.admin?(cookie(headers, 'raid_admin')) }
        Thread.current[:set_cookie] = ['raid_is_admin=; Path=/; SameSite=Strict; Max-Age=0']
        return json({ 'error' => '관리자 로그인이 필요합니다.', 'login' => true }, 401)
      end
      return upload(data) if method == 'POST' && path == '/api/admin/upload'
      return admin(method, path, data, cookie(headers, 'raid_admin'))
    end

    [404, 'text/plain; charset=utf-8', 'Not Found']
  rescue RuntimeError => e
    json({ 'error' => e.message }, 400)
  end

  # 관리자 화면에서 줄여 보낸 이미지(data URL)를 app/data/img 에 저장하고 주소를 돌려준다
  def upload(d)
    m = d['data'].to_s.match(%r{\Adata:image/(jpeg|png|webp|gif);base64,([A-Za-z0-9+/=]+)\z})
    raise '이미지 파일만 올릴 수 있어요.' unless m
    bin = m[2].unpack1('m0')
    raise '이미지가 너무 커요 (1MB까지).' if bin.bytesize > 1_000_000
    ext = { 'jpeg' => 'jpg' }.fetch(m[1], m[1])
    name = "#{Digest::SHA1.hexdigest(bin)[0, 20]}.#{ext}"
    FileUtils.mkdir_p(IMG_DIR)
    File.binwrite(File.join(IMG_DIR, name), bin)
    json('url' => "/img/#{name}")
  end

  def cookie(headers, name)
    headers['cookie'].to_s.split(';').map(&:strip).each do |kv|
      k, v = kv.split('=', 2)
      return v.to_s if k == name
    end
    ''
  end

  def admin(method, path, d, token)
    e = @engine
    e.mutex.synchronize do
      case [method, path]
      when ['GET', '/api/admin'] then nil
      when ['POST', '/api/admin/table'] then e.save_table!(d['key'].to_s, Array(d['rows']))
      when ['POST', '/api/admin/heal'] then e.heal_all!
      when ['POST', '/api/admin/start'] then e.start_battle!(runners: d['runners'], creature_name: d['creature'].to_s, auto_mode: d['auto'], hps: d['hps'] || {})
      when ['POST', '/api/admin/boss'] then e.boss_command!(d['id'], skill: d['skill'], targets: d['targets'], cells: d['cells'])
      when ['POST', '/api/admin/auto'] then e.set_auto!(d['id'], d['on'])
      when ['POST', '/api/admin/settle'] then e.settle_now!(d['id'])
      when ['POST', '/api/admin/begin'] then e.begin_battle!(d['id'])
      when ['POST', '/api/admin/end'] then e.end_battle!(d['id'])
      when ['POST', '/api/admin/chat'] then e.admin_chat!(d['id'], d['text'])
      when ['POST', '/api/admin/password'] then e.change_password!(d['old'], d['new'], token)
      else return [404, 'text/plain; charset=utf-8', 'Not Found']
      end
      e.bump! unless method == 'GET'
      json(e.admin_view)
    end
  end

  def respond(client, code, type, body)
    reason = { 200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized', 404 => 'Not Found', 500 => 'Internal Server Error' }[code]
    body = body.to_s.b
    client.write("HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Cache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n" \
                 "#{Array(Thread.current[:set_cookie]).map { |c| "Set-Cookie: #{c}\r\n" }.join}Connection: close\r\n\r\n")
    client.write(body)
  end
end
