use strict;
use warnings;

use Test::More tests => 7;
use EntityModel::Log ':all';

# Check that we format messages correctly
my @messageList = (
	[ 'test' ], 'test',
	[ sub { 'subref' } ], 'subref',
	[ '%d', 15 ], '15',
	[ '%s', [ 15 ] ], '[15]',
	[ '%s %s %s', sub { split ' ', 'subref returning array' } ], 'subref returning array',
	[ sub { sub { 'nested sub' } } ], 'nested sub',
);

while(@messageList) {
	my $param = shift(@messageList);
	my $expected = shift(@messageList);
	is(EntityModel::Log->parseMessage(@$param), $expected, 'expect ' . $expected);
}

my $str = '';
open my $fh, '>', \$str or die $!;
$fh->autoflush(1);
EntityModel::Log->instance->handle($fh);

# Raise a log message to string and check that it matched
{
	local $EntityModel::Log::DISABLE = 0;
	logError("Testing");
	like($str, qr/Testing/, 'wrote to string handle');
}

