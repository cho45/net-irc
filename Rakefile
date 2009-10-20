require 'rubygems'
require "shipit"
require 'rake'
require 'rake/clean'
require 'rake/packagetask'
require 'rake/gempackagetask'
require 'rake/rdoctask'
require 'rake/contrib/sshpublisher'
require 'fileutils'
require 'spec/rake/spectask'

include FileUtils

$LOAD_PATH.unshift "lib"
require "net/irc"

NAME              = "net-irc"
AUTHOR            = "cho45"
EMAIL             = "cho45@lowreal.net"
DESCRIPTION       = "library for implementing IRC server and client"
HOMEPATH          = "http://cho45.stfuawsc.com/net-irc/"
BIN_FILES         = %w(  )
VERS              = Net::IRC::VERSION.dup

REV = File.read(".svn/entries")[/committed-rev="(d+)"/, 1] rescue nil
CLEAN.include ['**/.*.sw?', '*.gem', '.config']
RDOC_OPTS = [
	'--title', "#{NAME} documentation",
	"--charset", "utf-8",
	"--opname", "index.html",
	"--line-numbers",
	"--main", "README",
	"--inline-source",
]

task :default => [:spec]
task :package => [:clean]

Spec::Rake::SpecTask.new do |t|
	t.spec_opts = ['--options', "spec/spec.opts"]
	t.spec_files = FileList['spec/*_spec.rb']
	#t.rcov = true
end

spec = Gem::Specification.new do |s|
	s.name              = NAME
	s.version           = VERS
	s.platform          = Gem::Platform::RUBY
	s.has_rdoc          = true
	s.extra_rdoc_files  = ["README", "ChangeLog"]
	s.rdoc_options     += RDOC_OPTS + ['--exclude', '^(examples|extras)/']
	s.summary           = DESCRIPTION
	s.description       = DESCRIPTION
	s.author            = AUTHOR
	s.email             = EMAIL
	s.homepage          = HOMEPATH
	s.executables       = BIN_FILES
	s.bindir            = "bin"
	s.require_path      = "lib"
	s.autorequire       = ""

	#s.add_dependency('activesupport', '>=1.3.1')
	#s.required_ruby_version = '>= 1.8.2'

	s.files = %w(README ChangeLog Rakefile AUTHORS.txt) +
		Dir.glob("{bin,doc,spec,test,lib,templates,generator,extras,website,script}/**/*") +
		Dir.glob("ext/**/*.{h,c,rb}") +
		Dir.glob("examples/**/*.rb") +
		Dir.glob("tools/*.rb")

	s.extensions = FileList["ext/**/extconf.rb"].to_a
end

Rake::GemPackageTask.new(spec) do |p|
	p.need_tar = true
	p.gem_spec = spec
end

task :install do
	name = "#{NAME}-#{VERS}.gem"
	sh %{rake package}
	sh %{sudo gem install pkg/#{name}}
end

task :uninstall => [:clean] do
	sh %{sudo gem uninstall #{NAME}}
end

task :upload_doc => [:rdoc] do
	sh %{rsync --update -avptr html/ lowreal@cho45.stfuawsc.com:/virtual/lowreal/public_html/cho45.stfuawsc.com/net-irc}
end


Rake::RDocTask.new do |rdoc|
	rdoc.rdoc_dir = 'html'
	rdoc.options += RDOC_OPTS
	rdoc.template = "resh"
	#rdoc.template = "#{ENV['template']}.rb" if ENV['template']
	if ENV['DOC_FILES']
		rdoc.rdoc_files.include(ENV['DOC_FILES'].split(/,\s*/))
	else
		rdoc.rdoc_files.include('README', 'ChangeLog')
		rdoc.rdoc_files.include('lib/**/*.rb')
		rdoc.rdoc_files.include('ext/**/*.c')
	end
end

Rake::ShipitTask.new do |s|
	s.ChangeVersion "lib/net/irc.rb", "VERSION"
	s.Commit
	s.Task :clean, :package, :upload_doc
	s.Step.new {
	}.and {
		system("gem", "push", "pkg/net-irc-#{VERS}.gem")
	}
	s.Tag
	s.Twitter
end

task 'AUTHORS.txt' do
	File.open('AUTHORS.txt', 'w') do |f|
		f.puts "Core Authors::"
		f.puts `git shortlog -s -n lib`.gsub(/^\s*\d+\s*/, '')
		f.puts
		f.puts "Example Contributors::"
		f.puts `git shortlog -s -n examples`.gsub(/^\s*\d+\s*/, '')
	end
end

