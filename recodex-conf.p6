#!/usr/bin/perl6

recodexUrl => "https://recodex.mff.cuni.cz",

# file to store token generated in ReCodEx web interface
tokenFile => "%*ENV<HOME>/.config/recodex-token.txt",

# a directory for storing temporary files (incl. trailing slash)
tempDir => "/tmp/",

# path to the base code given to students for submitted file name
getBaseOfSolution => sub ($_) {
	# find file with the same name in git repository
	my $assignmentsGitPath = "%*ENV<HOME>/assignments/";
	return qqx{find '$assignmentsGitPath' -name '$_' | head -n 1}.chomp || "/dev/null";
},

# shell command for opening submitted file and removing it
showFileAndRemove => sub ($_) {
	when m/\/$/ {
		# open a directory with multiple files in bash
		shell qq{cd '$_'; bash; rm -r '$_'};
	}
	when m:i/\.pdf$/ {
		# open PDF in zathura
		shell qq{zathura '$_'; rm '$_'};
	}
	default {
		# open other files in vim
		shell qq{vim '$_'; rm '$_'};
	}
},

# the same as previous but optionally asynchronous,
# modification of comments and points will be invoked just after it
showFileAndRemoveAsync => sub ($_) {
	given $_ {
		when m/\/$/ {
			# open a directory with multiple files in bash in a new xterm window
			shell qq{(cd '$_'; xterm; rm -r '$_') &};
		}
		when m:i/\.pdf$/ {
			# open PDF in zathura
			shell qq{(zathura '$_'; rm '$_') &};
		}
		default {
			# open other files in vim in a new xterm window
			shell qq{(xterm -e bash -ic "vim '$_'"; rm '$_') &};
		}
	}
},

# shell command for showing diff of two files and removing them
showDiffAndRemove => sub ($fileA, $fileB) {
	# use vimdiff (it's up to user not to use it on PDFs)
	shell qq{vimdiff '$fileA' '$fileB'; rm '$fileA' '$fileB'};
},

# asynchronous version of the previous
showDiffAndRemoveAsync => sub ($fileA, $fileB) {
	# use vimdiff in a new xterm window
	shell qq{(xterm -e bash -ic "vimdiff '$fileA' '$fileB'"; rm '$fileA' '$fileB') &};
},

# shell command for text file modification,
# cursor should be placed on the specified line
editFile => sub ($file, $cursorLine = 1) {
	# use vim
	shell qq{vim '$file' +'$cursorLine'};
},

# shell command for opening web page
openWeb => sub ($_) {
	# open url in qutebrowser
	shell qq{qutebrowser '$_' >/dev/null 2>&1 &};
},

# terminal codes of colors to be used
color => {
	C      => "\e[38;5;2m",   # correct  (green)
	W      => "\e[38;5;1m",   # wrong    (red)
	A      => "\e[38;5;39m",  # accepted (light blue -- needs 256-color terminal)
	normal => "\e[0m"};

