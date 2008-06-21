#!/usr/bin/env ruby
=begin


## Licence

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "json"
require "net/irc"
require "mechanize"

class Mixi
	def initialize(email, password, mixi_premium = false, image_dir = '~/.vim/mixi_images')
		require 'kconv'
		require 'rubygems'
		require 'mechanize'

		@image_dir = File.expand_path image_dir
		@email, @password, @mixi_premium =
			email, password, mixi_premium
		@agent = WWW::Mechanize.new
		@agent.user_agent_alias = 'Mac Safari'
	end

	def post(title, body, images)
		page = @agent.get 'http://mixi.jp/home.pl'
		form = page.forms[0]
		form.email = @email
		form.password = @password
		@agent.submit form

		page = @agent.get "http://mixi.jp/home.pl"
		page = @agent.get page.links[18].uri
		form = page.forms[(@mixi_premium ? 1 : 0)]
		form.diary_title = title
		form.diary_body = self.class.magic_body(body)
		get_image images
		images[0, 3].each_with_index do |img, i|
			if /darwin/ =~ RUBY_PLATFORM && /\.png$/i =~ img
				imgjpg = '/tmp/mixi-vim-' << File.basename(img).sub(/\.png$/i, '.jpg')
				system "sips -s format jpeg --out #{imgjpg} #{img} > /dev/null 2>&1"
				img = imgjpg
			end
			form.file_uploads[i].file_name = img
		end
		page = @agent.submit form
		page = @agent.submit page.forms[0]
	end

	def get_latest
		page = @agent.get 'http://mixi.jp/list_diary.pl'
		["http://mixi.jp/" << page.links[37].uri.to_s.toutf8,
			page.links[37].text.toutf8]
	end

	def self.magic_body(body)
		body.gsub(/^(  )+/) {|i| '　'.toeuc * (i.length/2) }
	end

	def get_image(images)
		images.each_with_index do |img, i|
			if img =~ %r{^http://}
				path =
					File.join @image_dir, i.to_s + File.extname(img)
				unless File.exist? @image_dir
					Dir.mkdir @image_dir
				else
					Dir.chdir(@image_dir) do
						Dir.entries(@image_dir).
							each {|f| File.unlink f if File.file? f }
					end
				end
				system "wget -O #{path} #{img} > /dev/null 2>&1"
				if File.exist? path and !File.zero? path
					images[i] = path
				else
					images.delete_at i
				end
			end
		end
	end
end

class MixiDiary < Net::IRC::Server::Session
	def server_name
		"mixi"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#mixi"
	end

	def initialize(*args)
		super
		@ua = WWW::Mechanize.new
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @opts.name || @real.split(/\s+/)
		@opts ||= []

		@mixi = Mixi.new(@real, @pass)
		@cont = []
	end

	def on_disconnected
		@observer.kill rescue nil
	end

	def on_privmsg(m)
		super

		case m[1]
		when "."
			title, body = *@cont
			@mixi.post ">_<× <  #{title}".toeuc, body.toeuc, []
			@mixi.get_latest.each do |line|
				post server_name, NOTICE, main_channel, line.chomp
			end
		when " "
			@cont.clear
		else
			@cont << m[1]
		end
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
end

if __FILE__ == $0
	require "optparse"

	opts = {
	:port       => 16701,
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
		Net::IRC::Server.new(opts[:host], opts[:port], MixiDiary, opts).start
	end
end

# Local Variables:
# coding: utf-8
# End:
