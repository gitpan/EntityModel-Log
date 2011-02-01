package EntityModel::Log;
# ABSTRACT: Logging class used by EntityModel
use strict;
use warnings FATAL => 'all', NONFATAL => 'redefine';
use parent qw{Exporter};

our $VERSION = '0.001';

=head1 NAME

EntityModel::Log - simple logging support for L<EntityModel>

=head1 SYNOPSIS

 use EntityModel::Log ':all';
 logDebug("Test something");
 logInfo("Object [%s] found", $obj->name);
 logError("Fatal problem");
 logInfo(sub { my $str = heavy_operation(); return 'Failed: %s', $str });

=head1 DESCRIPTION

Yet another logging class. Provides a procedural and OO interface as usual.

=cut

# Need to be able to switch off logging in UNITCHECK stages, since that segfaults perl5.10.1 and possibly other versions
our $DISABLE = 0;

use Time::HiRes qw{time};
use POSIX qw{strftime};
use Exporter;
use List::Util qw{min max};
use IO::Handle;
use Data::Dump ();

our %EXPORT_TAGS = ( 'all' => [qw/&logDebug &logInfo &logWarning &logError &logStack/] );
our @EXPORT_OK = ( @{$EXPORT_TAGS{'all'}} );

# Internal singleton instance 
my $instance;
sub instance { my $class = shift; $instance ||= $class->new }

=head1 PROCEDURAL METHODS

=cut

my @LogType = (
	'Debug',
	'Info',
	'Warning',
	'ERROR'
);

sub logBase { __PACKAGE__->instance->raise(@_); }

=head2 logDebug

Raise a debug message, but only if the debug flag is set. Expect a high volume of these during normal operation
so live server has this switched off.

=cut

sub logDebug { unshift @_, 0; goto &logBase; }

=head2 logInfo

Raise an informational message, which we'd like to track for stats
reasons - indicates normal operations rather than an error condition.

=cut

sub logInfo { unshift @_, 1; goto &logBase; }

=head2 logWarning

Raise a warning message, for things like 'article does not exist', expect a few of these in regular operations
but they aren't serious enough to be potential bugs or system problems.

=cut

sub logWarning { unshift @_, 2; goto &logBase; }

=head2 logError

Raise an error - this is likely to be a genuine system problem.

=cut

sub logError { unshift @_, 3; goto &logBase; }

=head2 logStack

Raise an error with stack - this is likely to be a genuine system problem.

=cut

sub logStack {
	my $txt = __PACKAGE__->instance->parseMessage(@_);

	$txt .= join("\n", map {
		sprintf("%s:%s %s", $_->{filename}, $_->{line}, $_->{subroutine})
	} stackTrace());
	logBase(3, $txt);
}

=head2 stackTrace

Get a stack trace, as an array of hashref entries, skipping the top two levels.

=cut

sub stackTrace {
	my $idx = 1;
	my @trace;
	my $basePath = '';
	while($idx < 99 && (my @stack = caller($idx))) {
		my %info;
                foreach (qw/package filename line subroutine hasargs wantarray evaltext is_require hints bitmask hinthash/) {
			$info{$_} = (shift(@stack) // '');
		}
		if(0) { # could include source context using something like $info{filename} ~~ m{^$basePath/(.*)$} || $info{filename} ~~ m{^/perl-module-path/(.*)$}) {
			my $file = $1;
			if(-r $info{filename}) {
				my $start = max(0, ($info{line} // 0) - 5);
				$info{code} = '';
				open my $fh, '<', $info{filename} or die $!;
				if($start) {
					<$fh> for 0..$start;
				}
				$info{code} .= sprintf("%5d %s", $fh->input_line_number + 1, scalar(<$fh>)) for 0..10;
				close $fh;
			}
			$info{filename} = $file;
		}
		push @trace, \%info;
		++$idx;
	}
	return @trace;
}

sub levelFromString {
	my $str = lc(shift);
	my $idx = 0;
	foreach (@LogType) {
		return $idx if $str ~~ lc($_);
		++$idx;
	}
	die "Bad log level [$str]";
}

sub timestamp {
	my $now = Time::HiRes::time;
	return strftime("%Y-%m-%d %H:%M:%S", gmtime($now)) . sprintf(".%03d", int($now * 1000.0) % 1000.0);
}

=head2 OO METHODS

=cut

=head2 new

Constructor - currently doesn't do much.

=cut

sub new { bless { path => 'entitymodel.log' }, shift }

sub path {
	my $self = shift;
	if(@_) {
		$self->close if $self->isOpen;
		$self->{path} = shift;
		$self->open;
		return $self;
	}
	return $self->{path};
}

sub handle {
	my $self = shift;
	if(@_) {
		$self->close if $self->isOpen;
		$self->{handle} = shift;
		$self->isOpen(1);
		$self->pid($$);
		return $self;
	}
	return $self->{handle};
}

sub pid {
	my $self = shift;
	if(@_) {
		$self->{pid} = shift;
		return $self;
	}
	return $self->{pid};
}

sub isOpen {
	my $self = shift;
	if(@_) {
		$self->{isOpen} = shift;
		return $self;
	}
	return $self->{isOpen};
}

sub disabled {
	my $self = shift;
	if(@_) {
		$self->{disabled} = shift;
		return $self;
	}
	return $self->{disabled};
}

sub close : method {
	my $self = shift;
	return $self unless $self->isOpen;
	if($self->handle) {
		close $self->handle;
	}

# Clear handle *after* isOpen status
	$self->isOpen(0)->handle(undef);
}

sub open : method {
	my $self = shift;
	return $self if $self->isOpen;
	open my $fh, '>>', $self->path or die $! . " for " . $self->path;
	binmode $fh, ':encoding(utf8)';
	$fh->autoflush(1);
	$self->handle($fh)->isOpen(1)->pid($$);
}

sub reopen {
	my $self = shift;
	$self->close if $self->isOpen;
	$self->open;
	return $self;
}

=head2 parseMessage

Generate appropriate text based on whatever we get passed.

Each item in the parameter list is parsed first, then the resulting items are passed through L<sprintf>. If only a single item is in the list then the resulting string is returned directly.

Item parsing handles the following types:

=over 4

=item * Single string is passed through unchanged

=item * Any coderef is expanded in place

=item * Arrayref or hashref is expanded via L<Data::Dump>

=item * Other references are stringified

=item * Undef items are replaced with the text 'undef'

=back

=cut

sub parseMessage {
	my $self = shift;
	return '' unless @_;

# Decompose parameters into strings
	my @data;
	ITEM:
	while(@_) {
		my $entry = shift;

# Convert to string if we can
		if(my $ref = ref $entry) {
			if($ref ~~ /^CODE/) {
				unshift @_, $entry->();
				next ITEM;
			} elsif($ref ~~ [qw{ARRAY HASH}]) {
				$entry = Data::Dump::dump($entry);
			} else {
				$entry = "$entry";
			}
		}
		$entry //= 'undef';
		push @data, $entry;
	}

# Format appropriately
	my $fmt = shift(@data) // '';
	return $fmt unless @data;

	return sprintf($fmt, @data);
}

sub min_level {
	my $self = shift;
	if(@_) {
		$self->{min_level} = shift;
		return $self;
	}
	return $self->{min_level};
}

=head2 raise

Raise a log message

=over 4

=item * $level - numeric log level

=item * @data - message data

=back

=cut

sub raise {
	my $self = shift;
	return $self if $self->disabled;

	my $level = shift;
	my ($pkg, $file, $line, $sub) = caller(1);

# caller(0) gives us the wrong sub for our purposes - we want whatever raised the logXX line
	(undef, undef, undef, $sub) = caller(2);

# Apply minimum log level based on method, then class, then default 'info'
	my $minLevel = ($sub ? $self->{mask}->{$sub}->{level} : undef);
	$minLevel //= $self->{mask}->{$pkg}->{level};
	$minLevel //= $self->{min_level};
	$minLevel //= 1;
	return $self if $minLevel > $level;

	my $txt = $self->parseMessage(@_);

# Explicitly get time from Time::HiRes for ms accuracy
	my $ts = timestamp();

	my $type = sprintf("%-8.8s", $LogType[$level]);
	$self->reopen unless $$ ~~ $self->pid;
	$self->open unless $self->isOpen;
	$self->handle->print("$ts $type $file:$line $txt\n");
	return $self;
}


=head2 debug

Log a message at debug level.

=cut

sub debug {
	my $self = shift;
}

END { $instance->close if $instance; }

1;

=head1 AUTHOR

Tom Molesworth <cpan@entitymodel.com>

=head1 LICENSE

Copyright Tom Molesworth 2008-2011. Licensed under the same terms as Perl itself.

