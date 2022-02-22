#!/usr/bin/env python3

#
# LMS-BlissMixer
#
# Copyright (c) 2022 Craig Drummond <craig.p.drummond@gmail.com>
# MIT license.
#

import datetime, os, requests, shutil, subprocess, tempfile, time

PLUGIN_NAME = "BlissMixer"
GITHUB_TOKEN_FILE = "%s/.config/github-token" % os.path.expanduser('~')
GITHUB_REPO = "CDrummond/bliss-mixer"
GITHUB_ARTIFACTS = ["bliss-mixer-linux", "bliss-mixer-mac", "bliss-mixer.exe"]
GITHUB_ARTIFACT_ZIPS = ["linux.zip", "mac.zip", "windows.zip"]
ARTIFACT_MAP = { "armhf-linux/bliss-mixer":  "armhf-linux/bliss-mixer",
                 "arm-linux/bliss-mixer":    "arm-linux/bliss-mixer",
                 "x86_64-linux/bliss-mixer": "x86_64-linux/bliss-mixer",
                 "bliss-mixer":              "darwin/bliss-mixer",
                 "bliss-mixer.exe":          "windows/bliss-mixer.exe"}

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
    for a in artifacts:
        if a in items:
            resp.append(items[a]["url"])
    return resp


def download_artifacts():
    urls = get_urls(GITHUB_REPO, GITHUB_ARTIFACTS)
    if len(urls)!=len(GITHUB_ARTIFACTS):
        error("Failed to determine all artifacts")
    token = None
    with open(GITHUB_TOKEN_FILE, "r") as f:
        token = f.readlines()[0].strip()
    headers = {"Authorization": "token %s" % token};
    ok = True
    with tempfile.TemporaryDirectory() as td:
        i = 0
        for url in urls:
            info("Downloading %s" % url)
            r = requests.get(url, headers=headers, stream=True)
            dest = os.path.join(td, GITHUB_ARTIFACT_ZIPS[i])
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
 
        for a in ARTIFACT_MAP:
            adest = "%s/%s/Bin/%s" % (os.path.dirname(os.path.abspath(__file__)), PLUGIN_NAME, ARTIFACT_MAP[a])
            info("Moving %s to %s" % (a, adest))
            shutil.move("%s/%s" % (td, a), adest)
            subprocess.call(["chmod", "a+x", adest], shell=False)

    if not ok:
        error("Failed to download artifacts")

download_artifacts()

