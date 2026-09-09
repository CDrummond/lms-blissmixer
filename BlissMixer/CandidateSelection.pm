package Plugins::BlissMixer::CandidateSelection;

#
# LMS Bliss Mixer
#
# Licence: GPL v3
#

use strict;

sub candidatePoolMultiplier {
    my ($lastfmEnabled, $playCountInfluence) = @_;

    my $multiplier = $lastfmEnabled ? 10 : 1;
    my $influence = abs(int($playCountInfluence || 0));
    $influence = 100 if $influence > 100;
    if ($influence) {
        my $playCountMultiplier = 1 + int(0.5 + (9 * $influence / 100));
        $playCountMultiplier = 2 if $playCountMultiplier < 2;
        $multiplier = $playCountMultiplier if $playCountMultiplier > $multiplier;
    }

    return $multiplier;
}

sub _playCountWeight {
    my ($percentile, $influence) = @_;
    $percentile = -1 if $percentile < -1;
    $percentile = 1 if $percentile > 1;
    $influence = -100 if $influence < -100;
    $influence = 100 if $influence > 100;

    # At either extreme the preferred end of the play-count range has 100:1
    # odds over the other end. At +/-50 the ratio is 10:1.
    return exp(log(10) * ($influence / 100) * $percentile);
}

sub _entries {
    my $tracks = shift;
    my @entries;
    my $unknown = 0;

    for my $index (0 .. $#$tracks) {
        my $track = $tracks->[$index];
        my $raw = eval { $track->playcount };
        $unknown++ unless defined $raw;
        my $count = defined $raw && $raw > 0 ? int($raw) : 0;
        push @entries, {
            track => $track,
            rank => $index + 1,
            playcount => $count,
            play_percentile => 0,
        };
    }

    my @ordered = sort {
        $a->{playcount} <=> $b->{playcount} || $a->{rank} <=> $b->{rank}
    } @entries;
    my $distinct = 0;
    my $position = 0;
    while ($position < @ordered) {
        my $end = $position;
        $end++ while $end + 1 < @ordered
            && $ordered[$end + 1]->{playcount} == $ordered[$position]->{playcount};
        my $average = ($position + $end) / 2;
        my $percentile = @ordered > 1 ? (2 * $average / $#ordered) - 1 : 0;
        $ordered[$_]->{play_percentile} = $percentile for $position .. $end;
        $distinct++;
        $position = $end + 1;
    }

    return (\@entries, $distinct, $unknown);
}

sub _artistKey {
    my $artist = shift;
    my $key = lc($artist || '');
    $key =~ s/^\s+|\s+$//g;
    return $key;
}

sub _lastfmWeightForTarget {
    my ($targetPercent, $endorsedWeight, $otherWeight) = @_;

    return 1 if $endorsedWeight <= 0 || $otherWeight <= 0;
    return 1000000 if $targetPercent >= 100;

    my $target = $targetPercent / 100.0;
    my $weight = ($target * $otherWeight)
        / ((1.0 - $target) * $endorsedWeight);
    return $weight > 0 ? $weight : 0.000001;
}

sub selectCandidates {
    my ($tracks, $finalCount, $playCountInfluence, $lastfmArtists,
        $lastfmTarget, $random, $extraWeightCallback) = @_;

    return {
        selected => [],
        entries => [],
        pool_size => 0,
        reranked => 0,
        effective_playcount_influence => 0,
        unknown_playcounts => 0,
        distinct_playcounts => 0,
        endorsed_count => 0,
        other_count => 0,
        lastfm_weight => 1,
        extra_weighting => 0,
    } unless $tracks && @$tracks;

    $finalCount = int($finalCount || 0);
    $finalCount = scalar @$tracks if $finalCount < 1;
    $finalCount = scalar @$tracks if $finalCount > scalar @$tracks;
    $playCountInfluence = int($playCountInfluence || 0);
    $playCountInfluence = -100 if $playCountInfluence < -100;
    $playCountInfluence = 100 if $playCountInfluence > 100;
    $lastfmTarget = int($lastfmTarget || 0);
    $lastfmTarget = 0 if $lastfmTarget < 0;
    $lastfmTarget = 100 if $lastfmTarget > 100;
    $random ||= sub { rand() };

    my ($entries, $distinctCounts, $unknownCounts) = _entries($tracks);
    my $effectivePlayCountInfluence = $distinctCounts > 1
        ? $playCountInfluence : 0;
    my ($endorsedCount, $otherCount) = (0, 0);

    if ($lastfmArtists && $lastfmTarget > 0) {
        for my $entry (@$entries) {
            my $artistKey = _artistKey(eval { $entry->{track}->artistName });
            $entry->{endorsed} = exists $lastfmArtists->{$artistKey} ? 1 : 0;
            $entry->{endorsed} ? $endorsedCount++ : $otherCount++;
        }
    } else {
        $_->{endorsed} = 0 for @$entries;
    }

    my $effectiveExtraWeighting = 0;
    for my $entry (@$entries) {
        my $extraWeight = $extraWeightCallback
            ? $extraWeightCallback->($entry->{track}, $entry)
            : 1;
        $extraWeight = 1 unless defined $extraWeight && $extraWeight > 0;
        $entry->{extra_weight} = $extraWeight;
        $effectiveExtraWeighting = 1 if abs($extraWeight - 1) > 0.000001;
    }

    my $effectiveLastfm = $lastfmTarget > 0
        && $endorsedCount > 0 && $otherCount > 0;
    my $reranked = $effectivePlayCountInfluence || $effectiveLastfm
        || $effectiveExtraWeighting;

    unless ($reranked) {
        my @selected = @$entries[0 .. $finalCount - 1];
        return {
            selected => \@selected,
            entries => $entries,
            pool_size => scalar @$entries,
            reranked => 0,
            effective_playcount_influence => 0,
            unknown_playcounts => $unknownCounts,
            distinct_playcounts => $distinctCounts,
            endorsed_count => $endorsedCount,
            other_count => $otherCount,
            lastfm_weight => 1,
            extra_weighting => $effectiveExtraWeighting,
        };
    }

    my $poolSize = scalar @$entries;
    my ($endorsedBaseWeight, $otherBaseWeight) = (0, 0);
    for my $entry (@$entries) {
        my $rankFraction = $poolSize > 1
            ? ($entry->{rank} - 1) / ($poolSize - 1) : 0;
        my $similarityWeight = exp(-log(10) * $rankFraction);
        my $playCountWeight = $effectivePlayCountInfluence
            ? _playCountWeight(
                $entry->{play_percentile}, $effectivePlayCountInfluence
            )
            : 1;
        my $baseWeight = $similarityWeight * $playCountWeight;
        $entry->{similarity_weight} = $similarityWeight;
        $entry->{playcount_weight} = $playCountWeight;
        $entry->{base_weight} = $baseWeight;
        if ($effectiveLastfm && $entry->{endorsed}) {
            $endorsedBaseWeight += $baseWeight;
        } else {
            $otherBaseWeight += $baseWeight;
        }
    }

    my $lastfmWeight = $effectiveLastfm
        ? _lastfmWeightForTarget(
            $lastfmTarget, $endorsedBaseWeight, $otherBaseWeight
        )
        : 1;

    for my $entry (@$entries) {
        my $artistWeight = $effectiveLastfm && $entry->{endorsed}
            ? $lastfmWeight : 1;
        my $weight = $entry->{base_weight} * $artistWeight
            * $entry->{extra_weight};
        $entry->{lastfm_weight} = $artistWeight;
        $entry->{weight} = $weight;
        my $value = $random->();
        $value = 0.000000000001 unless defined $value && $value > 0;
        $value = 1 if $value > 1;
        $entry->{key} = $value ** (1 / $weight);
    }

    my @selected = sort {
        $b->{key} <=> $a->{key} || $a->{rank} <=> $b->{rank}
    } @$entries;
    splice(@selected, $finalCount) if @selected > $finalCount;

    return {
        selected => \@selected,
        entries => $entries,
        pool_size => $poolSize,
        reranked => 1,
        effective_playcount_influence => $effectivePlayCountInfluence,
        unknown_playcounts => $unknownCounts,
        distinct_playcounts => $distinctCounts,
        endorsed_count => $endorsedCount,
        other_count => $otherCount,
        lastfm_weight => $lastfmWeight,
        extra_weighting => $effectiveExtraWeighting,
    };
}

sub selectionLogLines {
    my ($selected, $poolSize, $showPlayCount) = @_;
    my $rankWidth = length("$poolSize");
    my $tierWidth = 0;
    my $playCountWidth = 1;

    for my $entry (@{$selected || []}) {
        my $tier = $entry->{endorsed} ? 'last.fm-endorsed' : 'bliss-only';
        my $length = length($tier);
        $tierWidth = $length if $length > $tierWidth;
        my $playLength = length('' . ($entry->{playcount} || 0));
        $playCountWidth = $playLength if $playLength > $playCountWidth;
    }
    $tierWidth += 2;

    my @lines;
    for my $entry (@{$selected || []}) {
        my $tier = $entry->{endorsed} ? 'last.fm-endorsed' : 'bliss-only';
        my $padding = $tierWidth - length($tier);
        my $leftPadding = ' ' x int($padding / 2);
        my $rightPadding = ' ' x ($padding - int($padding / 2));
        my $playCount = $showPlayCount
            ? sprintf('playcount=%*d | ', $playCountWidth, $entry->{playcount} || 0)
            : '';
        push @lines, sprintf(
            '  [%s%s%s| %ssimilarity-rank %*d/%d ] %s - %s',
            $leftPadding, $tier, $rightPadding, $playCount,
            $rankWidth, $entry->{rank}, $poolSize,
            $entry->{track}->artistName, $entry->{track}->title,
        );
    }

    return \@lines;
}

1;

__END__
