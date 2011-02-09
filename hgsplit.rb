#!/usr/bin/ruby

# (c) 2011 Yoann Guillot
# License: WtfPLv2
#
# From a mercurial repository, create a new repo tracking history for a subset of the files
#
# usage: hgsplit <file1> <file2> <file3>
#
# works with mercurial, could work with git/* with few changes (check runhg invocations, adapt arguments)
#
# (!) subrepo history is saved as linear even if there were branches/merges
#
# (!) only 1st line of commit msg is saved !
#
# works with a list of explicit full file names, use --regex to work with partial names/regexps

require 'optparse'
require 'digest/md5'
require 'fileutils'

$opts = { :subrepo => 'subrepo', :flist => [] }
OptionParser.new { |o|
	o.on('-d <path>', '--subrepo <path>', 'path to the directory that will hold the repo') { |p| $opts[:subrepo] = p }
	o.on('-s <path>', '--repo <path>', 'path to the repository to split') { |p| $opts[:mainrepo] = p }
	o.on('-x', '--exclude', 'ignore files in the filelist, include all others') { $opts[:exclude] = true }
	o.on('-r', '--regex', 'the file list is a list of regexps') { $opts[:regex] = true }
	o.on('-i <cid>', '--initial-commit <commitid>', 'start from this commit (linear commit number - 0 == init)') { |o| $opts[:initialcommit] = o.to_i }
	o.on('-f <cid>', '--final-commit <commitid>', 'end at this commit (linear commit number)') { |o| $opts[:finalcommit] = o.to_i }
	o.on('-v', '--verbose', 'be verbose') { $VERBOSE = true }
	o.on('-l <listfile>', '--list <listfile>', 'file holding a list of files, one per line') { |f|
		$opts[:flist].concat IO.readlines(f).map { |l| l.chomp }
	}
}.parse!(ARGV)

Dir.chdir($opts[:mainrepo]) if $opts[:mainrepo]

$opts[:flist].concat ARGV

abort 'no filelist!' if $opts[:flist].empty? and not $opts[:exclude]

Dir.mkdir($opts[:subrepo])	# raise if already exists

def runsubdir
	Dir.chdir($opts[:subrepo]) { yield }
end

# run a hg command with the args, returns a hash containing the parsed outscreen
def runhg(args, raw=false)
	out = `hg #{args}`
	return out if raw
	lasttag = nil
	ret = {}
	out.strip.each_line { |l|
		if l =~ /^(\S+):(.*)/
			lasttag = $1
			ret[lasttag] = $2.strip
		elsif lasttag
			ret[lasttag] << "\n" << l.strip
		end
	}
	ret
end

# returns the list of files we should put in the subrepo
# eg $flist, or allfiles-$flist if '--exclude' was specified
def listtrackedfiles
	allfiles = runhg('status -c', true).lines.map { |l| l[2..-1].strip }
	if $opts[:regex]
		if $opts[:exclude]
			allfiles.reject { |f| $opts[:flist].find { |re| f =~ /#{re}/ } }
		else
			allfiles.find_all { |f| $opts[:flist].find { |re| f =~ /#{re}/ } }
		end
	else
		if $opts[:exclude]
			allfiles - $opts[:flist]
		else
			allfiles & $opts[:flist]
		end
	end
end

# copy tracked files from repo to subrepo, handles rm'd files
def copyfiles(oldstat, newstat)
	# copy changed files
	newstat.keys.each { |f|
		next if newstat[f] == oldstat[f]
		puts " copy #{f}" if $VERBOSE
		rf = File.join($opts[:subrepo], f)
		FileUtils.mkdir_p File.dirname(rf)
		File.open(rf, 'wb') { |fdw|
			File.open(f, 'rb') { |fdr|
				fdw.write fdr.read
			}
		}
	}
	# remove old deleted/moved files
	(oldstat.keys - newstat.keys).each { |f|
		puts " rm #{f}" if $VERBOSE
		runsubdir { File.unlink(f) }
	}
end

# stat the tracked files for changes
# XXX File.stat(f).mtime has 1s resolution, which may not be enough, so use fullfile md5
def getstats
	ret = {}
	listtrackedfiles.each { |f|
		ret[f] = Digest::MD5.file(f).hexdigest
	}
	ret
end

# handle uncommited changes
runhg "commit -m 'hgsplit'"

# create subrepo
runsubdir { runhg "init" }

$opts[:initialcommit] ||= 0
# find maximum incremental changeset number
$opts[:finalcommit] ||= runhg("tip")['changeset'].split(':')[0].to_i

# iterate over each changeset in history
stat = {}
ncommits = 0
nmax = $opts[:finalcommit] - $opts[:initialcommit] + 1
nmax.times { |ver|

	if $VERBOSE
		puts "commit #{ver}/#{nmax-1}"
	elsif $stderr.tty?
		$stderr.print "%.2f%%  \r" % (ver*100.0 / (nmax-1))
	end

	cid = ver + $opts[:initialcommit]
	runhg "update -c #{cid}"
	nstat = getstats
	# nothing to do if no tracked file changed
	next if nstat == stat

	ncommits += 1
	# propagate changes
	copyfiles(stat, nstat)
	# retrieve original commit info
	log = runhg "log -r #{cid}"
	# replicate commit
	runsubdir { runhg "commit -u #{log['user'].inspect} -d #{log['date'].inspect} -A -m #{log['summary'].inspect}" }

	stat = nstat
}

puts "subrepository saved to #{$opts[:subrepo]}/, saved #{ncommits} changes from #{nmax} total"
