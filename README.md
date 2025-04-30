# Bliss Mixer

LMS `Don't Stop The Music` plugin using [Bliss Mixer](https://github.com/CDrummond/bliss-mixer)
to provide random tracks similar to seed tracks chosen from the current play
queue.

[Bliss Mixer](https://github.com/CDrummond/bliss-mixer) requires that your music
is first analysed with [Bliss Analyser](https://github.com/CDrummond/bliss-analyser)


# LMS menus

3 entries are added to LMS' 'More'/context menus:

1. `Similar tracks` returns (up to) 50 tracks that are similar to the selected
track, returned in similarity order.
2. `Similar tracks by artist` returns (up to) 50 by the same artist that are
similar to the selected track, returned in similarity order.
3. `Create bliss mix` creates a mix of (up to) 50 tracks based upon the selected
artist, album, or track, returned in a shuffled order.

*NOTE* These menus do not currently work with the `Default` LMS web skin, but do
work with `Material Skin` and other controllers.


# URL for favourites, etc.

As of v0.6.0 the mixer can be started via the `blissmixer://` URL. This supports the following query items:

1. `artist` URL encoded artist name
2. `album` URL encoded album name
3. `path` URL encoded track path
4. `genre` URL encoded genre name
5. `count` number of tracks to return
6. `dstm` if set to `1` then `DSTM` is enabled for the player and set to `BlissMixer`

To start a mix based upon an artist, 15 tracks, and enable DSTM:
```
blissmixer://?artist=Iron%20Maiden&count=15&dstm=1
```

To start a mix based upon an album, then **both** `artist` and `album` must be specified:
```
blissmixer://?artist=Iron%20Maiden&album=Somewhere%20In%20Time
```

To start a mix based upon a single track:
```
blissmixer://?path=%2Fmedia%2Fmusic%2FIron%20Maiden%2FSomewhere%20In%20Time%2F02%20Wasted%20Years.mp3

```

To start a mix based upon a genre:
```
blissmixer://?genre=Heavy%20Metal

```

**NOTE** For safety strings should be URL escaped, as shown in the examples above. However, if they do not contain `?`, `&`, `=`, or `#`, it *might* be OK to use the plain strings - e.g.

```
blissmixer://?artist=Iron Maiden&album=Somewhere In Time
```