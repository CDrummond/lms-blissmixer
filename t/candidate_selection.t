use strict;
use warnings;

use Test::More;

require './BlissMixer/CandidateSelection.pm';

{
    package Local::Track;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub artistName { return shift->{artist}; }
    sub title { return shift->{title}; }
    sub url { return shift->{url}; }
    sub playcount { return shift->{playcount}; }
}

sub track {
    my ($number, $playcount, $artist) = @_;
    return Local::Track->new(
        artist => $artist || "Artist $number",
        title => "Track $number",
        url => "file:///track-$number.flac",
        playcount => $playcount,
    );
}

is(
    Plugins::BlissMixer::CandidateSelection::candidatePoolMultiplier(0, 0),
    1,
    'candidate pool is not expanded when refinements are disabled',
);
is(
    Plugins::BlissMixer::CandidateSelection::candidatePoolMultiplier(1, 0),
    10,
    'Last.fm uses the existing tenfold candidate pool',
);
is(
    Plugins::BlissMixer::CandidateSelection::candidatePoolMultiplier(0, 1),
    2,
    'non-zero play-count influence expands the candidate pool',
);
is(
    Plugins::BlissMixer::CandidateSelection::candidatePoolMultiplier(1, 100),
    10,
    'candidate pool requirements use the maximum rather than multiplying',
);

my @ordered = (
    track(1, 0),
    track(2, 20),
    track(3, 10),
);
my $unchanged = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@ordered, 2, 0, undef, 0, sub { 0.5 }
);
is_deeply(
    [map { $_->{track}->url } @{$unchanged->{selected}}],
    ['file:///track-1.flac', 'file:///track-2.flac'],
    'disabled refinements retain Bliss candidate order',
);
ok(!$unchanged->{reranked}, 'disabled refinements are reported as inactive');

my $preferFrequent = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@ordered, 1, 100, undef, 0, sub { 0.5 }
);
is(
    $preferFrequent->{selected}->[0]->{track}->url,
    'file:///track-2.flac',
    'positive influence prefers a frequently played track',
);

my $preferRare = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@ordered, 1, -100, undef, 0, sub { 0.5 }
);
is(
    $preferRare->{selected}->[0]->{track}->url,
    'file:///track-1.flac',
    'negative influence prefers an unplayed track',
);

my @sameCounts = (
    track(1, 5),
    track(2, 5),
    track(3, 5),
);
my $noVariation = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@sameCounts, 2, 75, undef, 0, sub { 0.5 }
);
is_deeply(
    [map { $_->{track}->url } @{$noVariation->{selected}}],
    ['file:///track-1.flac', 'file:///track-2.flac'],
    'identical play counts retain Bliss candidate order',
);
is(
    $noVariation->{effective_playcount_influence},
    0,
    'identical play counts disable the play-count factor',
);

my @artistCandidates = (
    track(1, 0, 'Bliss Artist'),
    track(2, 0, 'Endorsed Artist'),
);
my $lastfm = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@artistCandidates, 1, 0, {'endorsed artist' => 1}, 75, sub { 0.5 }
);
is(
    $lastfm->{selected}->[0]->{track}->url,
    'file:///track-2.flac',
    'Last.fm target can promote an endorsed candidate over a higher Bliss rank',
);
ok($lastfm->{reranked}, 'Last.fm artist variation activates reranking');

my $noEndorsements = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@artistCandidates, 1, 0, {}, 75, sub { 0.5 }
);
is(
    $noEndorsements->{selected}->[0]->{track}->url,
    'file:///track-1.flac',
    'no matching Last.fm artists retain Bliss candidate order',
);
ok(!$noEndorsements->{reranked}, 'no Last.fm variation is reported as inactive');

my $combined = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@ordered, 2, -50, {'artist 2' => 1}, 50, sub { 0.5 }
);
ok($combined->{reranked}, 'Last.fm and play count share one reranking pass');
is(scalar @{$combined->{selected}}, 2, 'combined reranking returns requested count');

my $extended = Plugins::BlissMixer::CandidateSelection::selectCandidates(
    \@ordered, 1, 0, undef, 0, sub { 0.5 }, sub {
        my ($candidate, $entry) = @_;
        return $candidate->url eq 'file:///track-3.flac' ? 100 : 1;
    }
);
is(
    $extended->{selected}->[0]->{track}->url,
    'file:///track-3.flac',
    'an optional extension weight participates in the common reranking pass',
);
ok($extended->{extra_weighting}, 'extension weighting is reported as active');

my $logLines = Plugins::BlissMixer::CandidateSelection::selectionLogLines(
    $combined->{selected}, $combined->{pool_size}, 1
);
is(scalar @$logLines, 2, 'one informational log line is produced per selection');
like(
    $logLines->[0],
    qr/^  \[ .* \| playcount=\s*\d+ \| similarity-rank \s*\d+\/3 \] /,
    'selection log uses aligned, bracketed columns',
);

done_testing();
