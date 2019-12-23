#!/usr/bin/perl6
# written by Lukáš Ondráček <ondracek@ktiml.mff.cuni.cz>, use under GNU GPLv3

use v6;
use JSON::Tiny;
#use Data::Dump;
use HTTP::UserAgent;


# read configuration from ~/.config/recodex-conf.p6
my %conf = "%*ENV<HOME>/.config/recodex-conf.p6".IO.slurp.EVAL;

my $token = %conf<tokenFile>.IO.slurp.trim;


# --- communication with ReCodEx API ---

# each access to ReCodEx uses this function
sub request(Str $path, Bool:D :$raw = False, Hash :$post-data, Bool:D :$delete = False) {
	state $ua = HTTP::UserAgent.new;
	my $res;
	if $delete {
		$res = $ua.delete("%conf<recodexUrl>/api/v1/$path", :Authorization("Bearer $token"));
	} orwith $post-data {
		$res = $ua.post("%conf<recodexUrl>/api/v1/$path", $post-data, :Authorization("Bearer $token"));
	} else {
		$res = $ua.get("%conf<recodexUrl>/api/v1/$path", :Authorization("Bearer $token"));
	}
	die unless $res.is-success;
	return $res.content if $raw;
	$res = from-json $res.content;
	die unless $res<success>;
	return $res<payload>;
	CATCH { say "Request error: $path"; exit }
}

sub requestFile(Str $id, Str $path) {
	spurt $path, request("uploaded-files/$id/download", :raw), :bin;
	return $path;
}

sub requestSolutionFile($solution) {
	with $solution<localFile> { # workaround for base solutions
		copy($_, %conf<tempDir> ~ $solution<localName>);
		return %conf<tempDir> ~ $solution<localName>;
	}

	my $dstDir = %conf<tempDir>;
	mkdir($dstDir ~= $_) with $solution<solution><localDirName>;
		
	with $solution<solution><files> {
		my $lastName;
		requestFile($_<id>, $lastName = $dstDir ~ $_<localName>) for @$_;
		return $solution<solution><localDirName> ?? $dstDir !! $lastName;
	}
}

# each modifying access to ReCodEx uses one of the following three functions

sub requestPointsUpdate(Str $solutionId, $bonusPoints, $overriddenPoints) {
	my %post-data;
	with $overriddenPoints {
		say "Setting overridden points of $solutionId to $_...";
		%post-data<overriddenPoints> = $_;
	}
	with $bonusPoints // 0 {
		say "Setting bonus points of $solutionId to $_...";
		%post-data<bonusPoints> = $_;
	}
	request("assignment-solutions/$solutionId/bonus-points", :%post-data);
}

sub requestAcceptedStatusUpdate(Str $solutionId, Bool $isAccepted) {
	say "Setting accepted status of $solutionId to $isAccepted...";
	if $isAccepted {
		request("assignment-solutions/$solutionId/set-accepted", :post-data{});
	} else {
		request("assignment-solutions/$solutionId/unset-accepted", :delete);
	}
}

sub requestNewComment(Str:D $solutionId, Str:D $comment, Bool:D $isPrivate) {
	say "Creating new " ~ ("private " x $isPrivate) ~ "comment of $solutionId...";
	request("comments/$solutionId", :post-data{text => $comment, isPrivate => $isPrivate});
}


# --- comunication with user ---

# let user choose one of the given options,
# use :chosen to skip interaction with user forcing one option,
# (callback gets 1-based indices in @opts)
sub choose(&callback, *@opts, :$default is copy, :$chosen is copy) {
	for @opts {
		my @opt = $_ ~~ Pair ?? $_.kv !! (++$, $_);
		$default //= @opt[0];
		printf "%11s: %s\n", @opt;
	}
	$chosen //= $default if +@opts == 1;

	loop {
		print "Select [$default]: ";
		if $chosen {
			$chosen.say;
		} else {
			$chosen = get;
			without $chosen { say ""; exit } # EOF
			$chosen ||= $default;
		}
		try return callback $chosen;
		$chosen = Str;
	}
	LEAVE { say "" }
}

sub openRecodexWeb($path) {
	say "Opening in web browser...";
	%conf<openWeb>("%conf<recodexUrl>/$path");
}


# --- formatting and coloring strings ---

sub safeFileName(*@_) {
	return @_.join("-").samemark("a").lc.subst(" ","_",:g).subst(/<-[-_.a..z0..9]>/, "", :g);
}

sub formatDate(Int $timestamp) {
	return ~DateTime.new($timestamp, timezone=>DateTime.now.timezone, formatter=>{
		sprintf "%04d-%02d-%02d %02d:%02d", .year, .month, .day, .hour, .minute
	});
}

sub wrap(Str $str is copy, Int $width = 80) {
	my @lines;
	for [$str.lines] {
		while $_.chars > $width {
			my $pos = $_.rindex("\n", $width) // $_.rindex(" ", $width) // $width;
			@lines.push: $_.substr(0, $pos + 1).trim;
			$_.=substr($pos + 1);
		}
		@lines.push: $_.trim;
	}
	return @lines.join("\n").trim;
}

sub escColor($color, $_) {
	my ($begin, $end) = %conf<color>{$color, "normal"};
	return $_ unless $_;
	return S:g/^|$end/$/$begin/ ~ $end;
}



# --- global variables and the main loop ---

multi MAIN {
	my (@groups, $group, @students, %studentsById);
	my (@assignments, $assignment);
	my ($student, $studentI);
	my ($solutionX, $solutionY, $solutionXI);

	my $screen = "groups";
	loop { $screen = do given $screen {

		# show list of groups to choose from
		when "groups" {
			say "Groups:";
			@groups = request("groups").values.sort(*<id>);
			for @groups {
				$_<name> = $_<localizedTexts>[0]<name>;
				$_<label> = "$_<externalId>, $_<privateData><bindings><sis>, $_<name>";
			}
			choose {
				$group = @groups[$_-1] or fail;
			}, @groups>><label>;
			@students = |request("groups/$group<id>/students");
			%studentsById = @students.map({$_<id> => $_});
			"assignments";
		}

		# show list of assignments in the chosen group
		when "assignments" {
			say "Assignments in $group<name>:";
			@assignments = $group<privateData><assignments>.map({request "exercise-assignments/$_"}).sort({$_<firstDeadline>});
			$_<name> = $_<localizedTexts>[0]<name> for @assignments;
			choose {
				when "u" { "groups" }
				when "w" {
					openRecodexWeb "app/group/$group<id>/detail";
					"assignments"
				}
				default {
					$assignment = @assignments[$_-1] or fail;
					"assignment";
				}
			}, @assignments>><name>, "w" => "open group in web browser", "u" => "go up to groups", :default(+@assignments);
		}

		# show list of students and their results in the chosen assignment
		when "assignment" {
			say "Results of $assignment<name> in $group<name>:";
			my @solutions = |request("exercise-assignments/$assignment<id>/solutions");

			$_<solutions> = [] for @students;
			%studentsById{$_<solution><userId>}<solutions>.push: $_ for @solutions;

			for @students {
				given $_<solutions> {
					$_=.sort({$_<solution><createdAt>}).Array;
					for |$_ {
						$_<stat> = $_<lastSubmission><isCorrect> ?? "C" !! "W";
						$_<stat> = "A" if $_<accepted>;
						$_<lastStudentActionAt> = $_<solution><createdAt> if $_<stat> eq "C";
						my @info;
						$_<strPoints> = $_<actualPoints> ~ ("+" x ($_<bonusPoints> > 0)) ~ ($_<bonusPoints> || "");
						if $_<actualPoints> > 0 or $_<bonusPoints> != 0 {
							@info.push: $_<strPoints>;
						}
						if $_<commentsStats> {
							$_<lastStudentActionAt> = Nil;
							my $comments = "." x ($_<commentsStats><count>-1);
							if $_<commentsStats><last><user><id> eq $_<solution><userId> {
								$comments ~= "i";
								$_<lastStudentActionAt> = $_<commentsStats><last><postedAt>;
							} elsif $_<commentsStats><last><isPrivate> {
								$comments ~= "p";
							} else {
								$comments ~= "o";
							}
							@info.push: $comments;
						}
						$_<statDesc> = $_<stat> ~ (@info ?? "[" ~ @info.join("|") ~ "]" !! "");
					}
				}
				$_<label> = sprintf("%-30s", $_<fullName>) ~ $_<solutions>.map({escColor($_<stat>, $_<statDesc>)}).join(" ");
			}

			@students.=sort({ $_<solutions>[*-1]<lastStudentActionAt> // $_<fullName> });
			for @students.rotor(2=>-1) {
				$_[0]<label> ~= "\n" if defined ([^] $_)<solutions>[*-1]<lastStudentActionAt>;
			}
			try @students[*-1]<label> ~= "\n";

			choose {
				when "u" { "assignments" }
				when "w" {
					openRecodexWeb "app/assignment/$assignment<id>/stats";
					"assignment"
				}
				default {
					$student = @students[$_-1] or fail;
					$studentI= $_-1;
					"solutions"
				}
			}, @students>><label>, "w" => "open assignment results in web browser", "u" => "go up to list of assignments";
		}


		# show list of solutions of the chosen student of the chosen assignment
		when "solutions" {

			# update for the case of modification or adding comments
			$student<solutions> = request("exercise-assignments/$assignment<id>/users/$student<id>/solutions")
				.sort({$_<solution><createdAt>}).Array;
			
		
			for |$student<solutions> {
				$_<stat> = $_<lastSubmission><isCorrect> ?? "C" !! "W";
				$_<stat> = "A" if $_<accepted>;
				$_<strPoints> = $_<actualPoints> ~ ("+" x ($_<bonusPoints> > 0)) ~ ($_<bonusPoints> || "");

				if $_<commentsStats><count>//0 > 1 {
					$_<comments> = request("comments/$_<id>")<comments>;
					$_<comments>.=sort(*<postedAt>);
				} else {
					$_<comments> = [$_<commentsStats><last> // ()];
				}

				$_<label> =
					sprintf "%s  %3d%%  %8s  %s",
						formatDate($_<solution><createdAt>),
						$_<lastSubmission><evaluation><score>*100,
						"$_<strPoints>/$_<maxPoints>",
						"$_<runtimeEnvironmentId>" ~
						("  correct" x $_<lastSubmission><isCorrect>) ~
						("  accepted" x $_<accepted>) ~
						("  [$_<note>]" x ?$_<note>);
				$_<strComments> =
					$_<comments>.map({
						(
							formatDate($_<postedAt>) ~ "  " ~
							$_<user><name> ~
							("  (private)" x $_<isPrivate>) ~ "\n"
						).indent(4) ~
						wrap($_<text>).indent(8);
					}).join("\n\n");
				$_<strComments> = "\n\n" ~ $_<strComments> ~ "\n" if $_<strComments>;
				$_<desc> = escColor($_<stat>, $_<label>) ~ $_<strComments>.indent(9);
				$_<descPlain> = $_<label> ~ $_<strComments>;
				++state $i;
				my $singleFile = $_<solution><files>.elems == 1;
				$_<solution><localDirName> = safeFileName($student<fullName>, $i) ~ "/" unless $singleFile;
				for |$_<solution><files> {
					$_<localName> = safeFileName(($student<fullName>, $i) xx $singleFile, $_<name>);
				}
			}
			with $student<solutions>[*-1] {
				$_<desc descPlain> >>~=>> "\n" unless $_<strComments>;
			}

			say "$student<fullName>'s solutions of $assignment<name>:";
			my $solCnt = +$student<solutions>;
			sub getSolution(Int:D(Any) $i where 0 <= $i <= $solCnt, Int:D(Any) $filenameFromI where (1 <= $filenameFromI <= $solCnt) = 1) {
				if ($i > 0) {
					return $student<solutions>[$i-1];
				} else {
					my $filename = safeFileName($student<solutions>[$filenameFromI-1]<solution><files>[0]<name>);
					return {
						localFile => %conf<getBaseOfSolution>($filename),
						localName => "base-$filename"
					}
				}
			}
			choose {
				when "u" { "assignment" }
				when "n" {
					with @students[++$studentI] {
						$student = $_;
						"solutions";
					} else { "assignment" }
				}
				when /^(\d+)(m)?$/ {
					$solutionX  = getSolution $0 or fail;
					$solutionXI = $0-1;
					if $1 {
						"solutionOpenModify"
					} else {
						"solutionOpen"
					}
				}
				when /^(\d*)d(\d*)(m)?$/ {
					my $X = ~$1||$solCnt;
					$solutionY  = getSolution ~$0||$X-1, $X or fail;
					$solutionX  = getSolution $X or fail;
					$solutionXI = $X-1;
					if $2 {
						"solutionDiffModify"
					} else {
						"solutionDiff"
					}
				}
				when /^m(\d*)$/ {
					my $X = ~$0||$solCnt;
					$solutionX  = getSolution $X or fail;
					$solutionXI = $X-1;
					"solutionModify"
				}
				when /^w(\d*)$/ {
					openRecodexWeb("app/assignment/$assignment<id>/solution/" ~ $student<solutions>[(~$0||$solCnt)-1]<id>) or fail;
					"solutions"
				}
				default { fail };
			}, $student<solutions>>><desc>,
			"m[X]" => "modify points and comments of solution X, defaults to the last one",
			"X[m]" => "view solution X, use 0 for base code given to students; then optionally modify X",
			"[Y]d[X][m]" => "view diff of solutions Y and X, Y defaults to X-1; then opt. modify X",
			"w[X]" => "open solution detail in web browser",
			"u" => "go up to $assignment<name>",
			"n" => "go to the next student",
			:default(+$student<solutions>);
		}


		# show chosen solution or its diff
		when "solutionOpen" {
			my $file = requestSolutionFile $solutionX;
			say "Opening solution $file...";
			%conf<showFileAndRemove>("$file");
			"solutions"
		}
		when "solutionOpenModify" {
			my $file = requestSolutionFile $solutionX;
			say "Opening solution $file (async)...";
			%conf<showFileAndRemoveAsync>("$file");
			"solutionModify"
		}
		when "solutionDiff" {
			my $fileY = requestSolutionFile $solutionY;
			my $fileX = requestSolutionFile $solutionX;
			say "Opening diff of $fileY and $fileX...";
			%conf<showDiffAndRemove>($fileY, $fileX);
			"solutions"
		}
		when "solutionDiffModify" {
			my $fileY = requestSolutionFile $solutionY;
			my $fileX = requestSolutionFile $solutionX;
			say "Opening diff of $fileY and $fileX (async)...";
			%conf<showDiffAndRemoveAsync>($fileY, $fileX);
			"solutionModify"
		}


		# modifications of comments, points, and acceptance of the chosen solution
		when "solutionModify" {
			my @solutionsStr = $student<solutions>.map({
				(sprintf "%2d: %s", ++$, $_<descPlain>)
					==> split("\n")
					==> map({"# $_"})
					==> join("\n")});
			@solutionsStr[$solutionXI] ~= q:to/END/;
				
				#
				# To update bonus points use:
				# BP <num>
				# To update overridden points use:
				# PTS <num>
				# Using only one of BP and PTS resets the other.
				# To mark solution as accepted use:
				# ACC
				# To revoke solution as accepted use:
				# NOACC
				# To write a comment from here to end of file use:
				# NOTE   (all the following lines not #-prefixed are part of the comment)
				# To write a private comment use:
				# PNOTE
				
				
				END

			my $path = %conf<tempDir> ~ safeFileName($student<fullName>, ($solutionXI+1), "modify.txt");
			spurt $path, ("# $student<fullName>'s solutions of $assignment<name>:\n#", |@solutionsStr).join("\n");

			my $broken;
			my $repeat;
			repeat {
				$broken = False;
				$repeat = False;
				say "Editing file $path...";
				%conf<editFile>($path, @solutionsStr[0..$solutionXI].join("\n").lines.elems + 2);
				my $str = slurp $path;

				my ($accepted, $bp, $pts, @note, $notePrivate);

				for $str.lines {
					next when /^\s*\#/;
					if not defined $notePrivate {
						next when /^\s*$/;
						when /^BP\s+(<[+-]>?\d+)$/ {
							$bp = +$0;
						}
						when /^PTS\s+(\d+)$/ {
							$pts = +$0;
						}
						when /^ACC$/ {
							$accepted = True;
						}
						when /^NOACC$/ {
							$accepted = False;
						}
						when /^NOTE$/ {
							$notePrivate = False;
						}
						when /^PNOTE$/ {
							$notePrivate = True;
						}
						default {
							$broken = True;
							last;
						}
					} else {
						@note.push: $_ unless not @note and not $_;
					}
				}
				if not $broken {
					my $note = @note.join("\n").trim-trailing;

					last unless defined $accepted or defined $bp or defined $pts or $note;
					say "Requested changes of solution "~ ($solutionXI+1) ~" of $student<fullName>:";
					say "  ...changing accepted status to $_" with $accepted;
					say "  ...changing bonus points to $_" with $bp;
					say "  ...changing overridden points to $_" with $pts;
					if $note {
						say "  ...creating new " ~ ("private " x $notePrivate) ~ "comment:";
						wrap($note).indent(8).say;
					}
					say "Do you want to apply the changes?";
					choose {
						when "y" {
							requestAcceptedStatusUpdate($solutionX<id>, $_) with $accepted;
							requestPointsUpdate($solutionX<id>, $bp, $pts) with $bp // $pts;
							requestNewComment($solutionX<id>, $note, $notePrivate) if $note;
						}
						when "n" { }
						when "m" { $repeat = True }
						default  { fail }
					}, "y" => "yes", "n" => "no", "m" => "modify again";
				} else {
					say "Cannot parse the file, do you want to modify it again?";
					choose {
						when "n" { }
						when "m" { $repeat = True }
						default  { fail }
					}, "m" => "modify again", "n" => "no";
				}
			} while $repeat;

			unlink $path;
			"solutions"
		}

		default {last}
	}}
}

# --- non-interactive invocations ---

multi MAIN (Bool:D :$r) {
	say "Refreshing access token...";
	%conf<tokenFile>.IO.spurt:  request("/login/refresh", :post-data{})<accessToken>;
}
