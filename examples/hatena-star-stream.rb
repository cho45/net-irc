#!/usr/bin/env ruby
# vim:encoding=UTF-8:
=begin

## Licence

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" unless defined? ::Encoding # json use this

require "rubygems"
require "json"
require "net/http"
require "net/irc"
require "sdbm"
require "tmpdir"
require "nkf"
require 'mechanize'
require 'nokogiri'

class HatenaStarStream < Net::IRC::Server::Session
	def server_name
		"hatenastarstream"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#star"
	end

	def initialize(*a)
		super
		@ua = WWW::Mechanize.new
		@ua.max_history = 1
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @real.split(/\s+/)
		@opts = @opts.inject({}) {|r,i|
			key, value = i.split("=")
			r.update(key => value)
		}

		@uri = URI("http://s.hatena.ne.jp/#{@real}/report.json?api_key=#{@pass}")
		start_observer
	end

	def on_disconnected
		@observer.kill rescue nil
	end

	def on_privmsg(m)
	end

	def on_ctcp(target, message)
	end

	def on_whois(m)
	end

	def on_who(m)
	end

	def on_join(m)
	end

	def on_part(m)
	end

	private
	def start_observer
		@observer = Thread.start do
			Thread.abort_on_exception = true
			loop do
				begin
					@log.info "getting report..."
					@log.debug @uri.to_s
					data = JSON.parse(Net::HTTP.get(@uri.host, @uri.request_uri, @uri.port))

					db = SDBM.open("#{Dir.tmpdir}/#{@real}.db", 0666)
					data['entries'].reverse_each do |entry|
						stars = ((entry['colored_stars'] || []) + [ entry ]).inject([]) {|r,i|
							r.concat i['stars'].map {|s| Star.new(s, i['color'] || 'normal') }
						}

						indexes = Hash.new(1)
						s = stars.select {|star|
							id = "#{entry['uri']}::#{indexes[star.color]}"
							indexes[star.color] += 1
							if db.include?(id)
								false
							else
								db[id] = "1"
								true
							end
						}.inject([]) {|r,i|
							if r.last == i
								r.last.count += 1
							else
								r << i
							end
							r
						}

						if s.length > 0
							post server_name, NOTICE, main_channel, "#{entry['uri']} #{title(entry['uri'])}"
							if @opts.key?("metadata")
								post "metadata", NOTICE, main_channel,  JSON.generate({ "uri" => entry['uri'] })
							end
						end

						s.each do |star|
							post server_name, NOTICE, main_channel, "id:%s \x03%d%s%s\x030 %s" % [
								star.name,
								Star::Colors[star.color],
								((star.color == "normal") ? "☆" : "★") * ([star.count, 10].min),
								(star.count > 10) ? "(...#{star.count})" : "",
								star.quote
							]
						end
					end

				rescue Exception => e
					@log.error e.inspect
					@log.error e.backtrace
				ensure
					db.close rescue nil
				end
				sleep 60 * 5
			end
		end
	end

	def title(url)
		uri = URI(url)
		@ua.get(uri)

		text = ""
		case
		when uri.fragment
			fragment =  @ua.page.root.at("//*[@name = '#{uri.fragment}']") || @ua.page.root.at("//*[@id = '#{uri.fragment}']")

			text =  fragment.inner_text
			while fragment.respond_to? :parent
				text += (fragment.next && fragment.next.text.to_s).to_s
				fragment = fragment.parent
			end
		when uri.to_s =~ %r|^http://h.hatena.ne.jp/[^/]+/\d+|
			text = @ua.page.root.at("#main .entries .entry .list-body div.body").inner_text
		else
			text = @ua.page.root.at("//title").inner_text
		end
		text.gsub!(/\s+/, " ")
		text.strip!
		NKF.nkf("-w", text).split(//)[0..60].join
	rescue Exception => e
		@log.debug ["title:", e.inspect]
		""
	end

	class Star < OpenStruct
		Colors = {
			"purple" => 6,
			"blue"   => 2,
			"green"  => 3,
			"red"    => 4,
			"normal" => 8,
		}

		def initialize(obj, col="normal")
			super(obj)
			self.count = obj["count"].to_i  + 1
			self.color = col
		end

		def ==(other)
			self.color == other.color &&
			self.name  == other.name
		end
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
	:port       => 16702,
	:host       => "localhost",
	:log        => nil,
	:debug      => false,
	:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner  = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(foreground=false)
		trap("SIGINT")  { exit! 0 }
		trap("SIGTERM") { exit! 0 }
		trap("SIGHUP")  { exit! 0 }
		return yield if $DEBUG || foreground
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], HatenaStarStream, opts).start
	end
end

# Local Variables:
# coding: utf-8
# End:
