#!/usr/bin/ruby

# (c) 2011 Yoann Guillot
# License: WtfPLv2
# From a mercurial repository, create a new repo tracking history for a subset of the files
# usage: cd <repo root> ; hgsplit <file1> <file2> <file3>  # now check the subrepo/ directory
# works with mercurial, could work with git/* with few changes (check runhg invocations, adapt arguments)
# subrepo history is saved as linear even if there were branches/merges
# only 1st line of commit msg is saved !

require 'optparse'
require 'digest/md5'

$subrepo = 'subrepo'
$flist = []
OptionParser.new { |o|
	o.on('--subrepo <path>', 'path to the directory that will hold the repo') { |p| $subrepo = p }
	o.on('--repo <path>', 'path to the repository to split (specify last)') { |p| Dir.chdir(p) }
	o.on('--list <filelist>', 'file holding a list of files, one per line') { |f|
		$flist.concat IO.readlines(f).map { |l| l.chomp }
	}
}.parse!(ARGV)

$flist.concat ARGV

abort 'no filelist!' if $flist.empty?

Dir.mkdir($subrepo)	# raise if already exists

def runsubdir
	Dir.chdir($subrepo) { yield }
end

# run a hg command with the args, returns a hash containing the parsed outscreen
def runhg(args)
	out = `hg #{args}`
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

# copy tracked files from repo to subrepo, handles rm'd files
def copyfiles
	$flist.each { |f|
		rf = File.join($subrepo, f)
		if File.exist?(f)
			File.open(rf, 'wb') { |fdw|
				File.open(f, 'rb') { |fdr|
					fdw.write fdr.read
				}
			}
		elsif File.exist?(rf)
			File.unlink(rf)
		end
	}
end

# stat the tracked files for changes
# XXX File.stat(f).mtime has 1s resolution, which may not be enough, so use fullfile md5
def getstats
	ret = {}
	$flist.each { |f|
		ret[f] = Digest::MD5.file(f).hexdigest if File.exist?(f)
	}
	ret
end

# handle uncommited changes
runhg "commit -m 'hgsplit'"

# create subrepo
runsubdir { runhg "init" }

# find maximum incremental changeset number
maxver = runhg("tip")['changeset'].split(':')[0].to_i

# iterate over each changeset in history
stat = getstats
ncommits = 0
(0..maxver).each { |ver|
	$stderr.print "%.2f%%  \r" % (ver * 100.0 / maxver)
	runhg "update -c #{ver}"
	nstat = getstats
	next if nstat == stat
	stat = nstat
	ncommits += 1
	# if the changeset includes some of our files, propagate to subrepo
	log = runhg "log -r #{ver}"
	copyfiles
	runsubdir { runhg "commit -u #{log['user'].inspect} -d #{log['date'].inspect} -A -m #{log['summary'].inspect}" }
}

puts "subdirectory saved to #$subrepo/, saved #{ncommits} changes from #{maxver} total"
