# local_sheet.rb
# encoding: UTF-8
#
# 구글 시트 대신 data/raid.json 파일을 "시트"처럼 읽고 쓰는 클래스.
# 전투봇의 SheetManager를 그대로 상속하고 맨 아래 입출력(read/write/append)만
# 바꾸므로, 스탯 읽기·체력 기록 같은 기존 규칙 코드는 한 줄도 바뀌지 않는다.

require 'json'
require 'fileutils'

class LocalStore
  attr_reader :path

  def initialize(path, sample_path)
    @path = path
    unless File.exist?(path)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(sample_path, path)
    end
    @data = JSON.parse(File.read(path, encoding: 'UTF-8'))
  end

  def book(key)
    @data['books'][key] ||= {}
  end

  def to_h
    @data
  end

  def replace_tab!(book_key, tab, rows)
    book(book_key)[tab] = rows.map { |r| Array(r).map(&:to_s) }
    save!
  end

  def save!
    tmp = "#{@path}.tmp"
    File.write(tmp, JSON.pretty_generate(@data), encoding: 'UTF-8')
    File.rename(tmp, @path)
  rescue => e
    puts "[저장 오류] #{e.class}: #{e.message}"
  end
end

class LocalSheet < SheetManager
  def initialize(store, book_key)
    @store = store
    @book_key = book_key
  end

  def read(range)
    tab, c1, r1, c2, r2 = parse_range(range)
    rows = table(tab)
    r2 = rows.size - 1 if r2.nil? || r2 > rows.size - 1
    out = (r1..r2).map do |ri|
      row = rows[ri] || []
      cells = row[c1..(c2 || [row.size - 1, c1].max)] || []
      trim_tail(cells.map(&:to_s))
    end
    out.pop while out.any? && out.last.empty?
    out
  rescue => e
    puts "[로컬 시트 읽기 오류] #{range}: #{e.message}"
    []
  end

  def write(range, values)
    tab, c1, r1, = parse_range(range)
    rows = table(tab)
    Array(values).each_with_index do |vals, i|
      ri = r1 + i
      rows[ri] ||= []
      Array(vals).each_with_index do |v, j|
        ci = c1 + j
        (rows[ri].size...ci).each { |k| rows[ri][k] = '' }
        rows[ri][ci] = v.to_s
      end
    end
    rows.map! { |r| r || [] }
    @store.save!
    true
  rescue => e
    puts "[로컬 시트 쓰기 오류] #{range}: #{e.message}"
    false
  end

  def write_raw(range, values)
    write(range, values)
  end

  def append(range, values)
    tab, = parse_range(range)
    table(tab) << Array(values).map(&:to_s)
    @store.save!
    true
  end

  def append_battle_log(row)
    table('전투로그') << Array(row).map(&:to_s)
    table('전투로그').shift while table('전투로그').size > 500
    @store.save!
    true
  end

  def read_range(tab, cols)
    read("#{tab}!#{cols}")
  end

  private

  def table(tab)
    @store.book(@book_key)[tab] ||= []
  end

  def trim_tail(cells)
    cells.pop while cells.any? && cells.last.to_s.empty?
    cells
  end

  def col_index(letters)
    letters.chars.reduce(0) { |acc, ch| acc * 26 + (ch.ord - 64) } - 1
  end

  # "'스탯'!A2:M100", "보스스킬!A2:L300", "전투로그!A:E", "'실행'!A2" 등
  def parse_range(range)
    tab, cells = range.to_s.split('!', 2)
    tab = tab.to_s.delete("'")
    a, b = cells.to_s.split(':', 2)
    ma = a.to_s.match(/\A([A-Z]+)(\d*)\z/)
    mb = b.to_s.match(/\A([A-Z]+)(\d*)\z/)
    c1 = col_index(ma[1])
    r1 = ma[2].empty? ? 0 : ma[2].to_i - 1
    if mb
      c2 = col_index(mb[1])
      r2 = mb[2].empty? ? nil : mb[2].to_i - 1
    else
      c2 = c1
      r2 = ma[2].empty? ? nil : r1
    end
    [tab, c1, r1, c2, r2]
  end
end
