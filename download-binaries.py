#!/usr/bin/env python3

#
# LMS-BlissMixer
#
# Copyright (c) 2022-2025 Craig Drummond <craig.p.drummond@gmail.com>
# MIT license.
#

import datetime, hashlib, os, requests, shutil, subprocess, tempfile, time

PLUGIN_NAME = "BlissMixer"
GITHUB_TOKEN_FILE = "%s/.config/github-token" % os.path.expanduser('~')
MIXER_GITHUB_REPO = "CDrummond/bliss-mixer"
MIXER_GITHUB_ARTIFACTS = ["bliss-mixer-linux", "bliss-mixer-mac", "bliss-mixer.exe"]
MIXER_GITHUB_ARTIFACT_ZIPS = ["linux.zip", "mac.zip", "windows.zip"]
MIXER_ARTIFACT_MAP = { "armhf-linux/bliss-mixer":   "armhf-linux/bliss-mixer",
                       "aarch64-linux/bliss-mixer": "aarch64-linux/bliss-mixer",
                       "x86_64-linux/bliss-mixer":  "x86_64-linux/bliss-mixer",
                       "bliss-mixer":               "mac/bliss-mixer",
                       "bliss-mixer.exe":           "windows/bliss-mixer.exe"}
ANALYSER_GITHUB_REPO = "CDrummond/bliss-analyser"
ANALYSER_GITHUB_ARTIFACTS = ["bliss-analyser-linux-x86", "bliss-analyser-linux-arm", "bliss-analyser-mac", "bliss-analyser-windows"]
ANALYSER_GITHUB_ARTIFACT_ZIPS = ["linux-x86.zip", "linux-arm.zip", "mac.zip", "windows.zip"]
ANALYSER_ARTIFACT_MAP = { "armhf-linux/bliss-analyser":   "armhf-linux/bliss-analyser",
                          "aarch64-linux/bliss-analyser": "aarch64-linux/bliss-analyser",
                          "x86_64-linux/bliss-analyser":  "x86_64-linux/bliss-analyser",
                          "bliss-analyser":               "mac/bliss-analyser",
                          "bliss-analyser.exe":           "windows/bliss-analyser.exe"}


def info(s):
    print("INFO: %s" %s)


def error(s):
    print("ERROR: %s" % s)
    exit(-1)


def to_time(tstr):
    return time.mktime(datetime.datetime.strptime(tstr, "%Y-%m-%dT%H:%M:%SZ").timetuple())


def get_urls(repo, artifacts):
    info("Getting artifact list")
    js = requests.get("https://api.github.com/repos/%s/actions/artifacts" % repo).json()
    if js is None or not "artifacts" in js:
        error("Failed to list artifacts")

    items={}
    for a in js["artifacts"]:
        if a["name"] in artifacts and (not a["name"] in items or to_time(a["created_at"])>items[a["name"]]["date"]):
            items[a["name"]]={"date":to_time(a["created_at"]), "url":a["archive_download_url"]}

    resp=[]
    for a in artifacts:armhf
        if a in items:armhf
            if not data:
                break
            md5.update(data)
    return md5.hexdigest()


def download_artifacts(repo, artifacts, artifactZips, artifactMap):
    urls = get_urls(MIXER_GITHUB_REPO, artifacts)
    if len(urls)!=len(artifacts):
        error("Failed to determine all artifacts")
    token = None
    with open(GITHUB_TOKEN_FILE, "r") as f:
        token = f.readlines()[0].strip()
    headers = {"Authorization": "token %s" % token};
    ok = True
    updated = False
    with tempfile.TemporaryDirectory() as td:
        i = 0
        for url in urls:
            info("Downloading %s" % url)
            r = requests.get(url, headers=headers, stream=True)
            dest = os.path.join(td, artifactZips[i])
            with open(dest, 'wb') as f:
                for chunk in r.iter_content(chunk_size=1024*1024): 
                    if chunk:
                        f.write(chunk)
            if not os.path.exists(dest):
                info("Failed to download %s" % url)
                ok = False
                break
            subprocess.call(["unzip", dest, "-d", td], shell=False)
            i+=1

        for a in artifactMap:
            asrc = "%s/%s" % (td, a)
            adest = "%s/%s/Bin/%s" % (os.path.dirname(os.path.abspath(__file__)), PLUGIN_NAME, artifactMap[a])
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


download_artifacts(MIXER_GITHUB_REPO, MIXER_GITHUB_ARTIFACTS, MIXER_GITHUB_ARTIFACT_ZIPS, MIXER_ARTIFACT_MAP)
download_artifacts(ANALYSER_GITHUB_REPO,ANALYSER_GITHUB_ARTIFACTS, ANALYSER_GITHUB_ARTIFACT_ZIPS, ANALYSER_ARTIFACT_MAP)

