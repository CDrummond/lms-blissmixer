#!/usr/bin/env python3

#
# LMS-BlissMixer
#
# Copyright (c) 2022-2026 Craig Drummond <craig.p.drummond@gmail.com>
# MIT license.
#

import datetime, hashlib, os, requests, shutil, subprocess, tempfile, time

PLUGIN_NAME = "BlissMixer"
GITHUB_TOKEN_FILE = "%s/.config/github-token" % os.path.expanduser('~')
MIXER_GITHUB_REPO = "CDrummond/bliss-mixer"
MIXER_GITHUB_ARTIFACTS = {"bliss-mixer-linux-x86": {"bliss-mixer": "x86_64-linux/bliss-mixer"},
                          "bliss-mixer-linux-arm": {"bin/bliss-mixer-armhf": "armhf-linux/bliss-mixer", "bin/bliss-mixer-aarch64": "aarch64-linux/bliss-mixer"},
                          "bliss-mixer-mac":       {"bliss-mixer": "mac/bliss-mixer"},
                          "bliss-mixer-windows":   {"bliss-mixer.exe": "windows/bliss-mixer.exe"}}
ANALYSER_GITHUB_REPO = "CDrummond/bliss-analyser"
ANALYSER_GITHUB_ARTIFACTS = {"bliss-analyser-linux-x86-ffmpeg": {"bliss-analyser": "x86_64-linux/bliss-analyser"},
                             "bliss-analyser-linux-arm-ffmpeg": {"bin/bliss-analyser-aarch64": "aarch64-linux/bliss-analyser"},
                             "bliss-analyser-mac-symphonia":    {"bliss-analyser": "mac/bliss-analyser"},
                             "bliss-analyser-windows-ffmpeg": {
                                "bliss-analyser.exe": "windows/bliss-analyser.exe",
                                "avcodec-61.dll": "windows/avcodec-61.dll",
                                "avdevice-61.dll": "windows/avdevice-61.dll",
                                "avfilter-10.dll": "windows/avfilter-10.dll",
                                "avformat-61.dll": "windows/avformat-61.dll",
                                "avutil-59.dll": "windows/avutil-59.dll",
                                "postproc-58.dll": "windows/postproc-58.dll",
                                "swresample-5.dll": "windows/swresample-5.dll",
                                "swscale-8.dll": "windows/swscale-8.dll",
                                "vcruntime140.dll": "windows/vcruntime140.dll"
                             }}


def info(s):
    print("INFO: %s" %s)


def error(s):
    print("ERROR: %s" % s)
    exit(-1)


def to_time(tstr):
    return time.mktime(datetime.datetime.strptime(tstr, "%Y-%m-%dT%H:%M:%SZ").timetuple())


def get_items(repo, artifacts):
    info("Getting artifact list for %s" % repo)
    js = requests.get("https://api.github.com/repos/%s/actions/artifacts" % repo).json()
    if js is None or not "artifacts" in js:
        error("Failed to list artifacts")

    items={}
    for a in js["artifacts"]:
        if a["name"] in artifacts and (not a["name"] in items or to_time(a["created_at"])>items[a["name"]]["date"]):
            items[a["name"]]={"date":to_time(a["created_at"]), "url":a["archive_download_url"]}

    return items


def getMd5sum(path):
    if not os.path.exists(path):
        return '000'
    md5 = hashlib.md5()
    with open(path, 'rb') as f:
        while True:
            data = f.read(65535)
            if not data:
                break
            md5.update(data)
    return md5.hexdigest()


def download_artifacts(repo, artifacts):
    items = get_items(repo, artifacts)
    if len(items)!=len(artifacts):
        error("Failed to determine all artifacts (%d != %d)" % (len(items), len(artifacts)))
    token = None
    with open(GITHUB_TOKEN_FILE, "r") as f:
        token = f.readlines()[0].strip()
    headers = {"Authorization": "token %s" % token};
    ok = True
    updated = False

    for name in items:
        with tempfile.TemporaryDirectory() as td:
            artifact = artifacts[name]
            url = items[name]["url"]
            info("Downloading %s" % url)
            r = requests.get(url, headers=headers, stream=True)
            dest = os.path.join(td, name+".zip")
            with open(dest, 'wb') as f:
                for chunk in r.iter_content(chunk_size=1024*1024): 
                    if chunk:
                        f.write(chunk)
            if not os.path.exists(dest):
                info("Failed to download %s" % url)
                ok = False
                break
            subprocess.call(["unzip", dest, "-d", td], shell=False)

            for a in artifact:
                asrc = "%s/%s" % (td, a)
                adest = "%s/%s/Bin/%s" % (os.path.dirname(os.path.abspath(__file__)), PLUGIN_NAME, artifact[a])
                srcMd5 = getMd5sum(asrc)
                destMd5 = getMd5sum(adest)
                if srcMd5!=destMd5:
                    info("Moving %s to %s" % (a, adest))
                    shutil.move("%s/%s" % (td, a), adest)
                    subprocess.call(["chmod", "a+x", adest], shell=False)
                    updated = True

    if not ok:
        error("Failed to download artifacts")
    elif not updated:
        info("No changes")


download_artifacts(MIXER_GITHUB_REPO, MIXER_GITHUB_ARTIFACTS)
download_artifacts(ANALYSER_GITHUB_REPO, ANALYSER_GITHUB_ARTIFACTS)
