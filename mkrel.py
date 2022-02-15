#!/usr/bin/env python3

#
# LMS-BlissMixer
#
# Copyright (c) 2022 Craig Drummond <craig.p.drummond@gmail.com>
# MIT license.
#

import hashlib
import os
import re
import requests
import shutil
import sys


REPO_XML = "repo.xml"
PLUGIN_NAME = "BlissMixer"
PLUGIN_GIT_NAME = "lms-blissmixer"

def info(s):
    print("INFO: %s" %s)


def error(s):
    print("ERROR: %s" % s)
    exit(-1)


def usage():
    print("Usage: %s <major>.<minor>.<patch>" % sys.argv[0])
    exit(-1)


def checkVersion(version):
    try:
        parts=version.split('.')
        major=int(parts[0])
        minor=int(parts[1])
        patch=int(parts[2])
    except:
        error("Invalid version number")


def releaseUrl(version):
    return "https://github.com/CDrummond/%s/releases/download/%s/%s-%s.zip" % (PLUGIN_GIT_NAME, version, PLUGIN_GIT_NAME, version)


def checkVersionExists(version):
    url = releaseUrl(version)
    info("Checking %s" % url)
    request = requests.head(url)
    if request.status_code == 200 or request.status_code == 302:
        error("Version already exists")


def updateLine(line, startStr, endStr, updateStr):
    start=line.find(startStr)
    if start!=-1:
        start+=len(startStr)
        end=line.find(endStr, start)
        if end!=-1:
            return "%s%s%s" % (line[:start], updateStr, line[end:])
    return None


def updateInstallXml(version):
    lines=[]
    updated=False
    installXml = "%s/install.xml" % PLUGIN_NAME
    info("Updating %s" % installXml)
    with open(installXml, "r") as f:
        lines=f.readlines()
    for i in range(len(lines)):
        updated = updateLine(lines[i], "<version>", "</version>", version)
        if updated:
            lines[i]=updated
            updated=True
            break
    if not updated:
        error("Failed to update version in %s" % installXml)
    with open(installXml, "w") as f:
        for line in lines:
            f.write(line)

        
def createZip(version):
    info("Creating ZIP")
    zipFile="%s-%s" % (PLUGIN_GIT_NAME, version)
    shutil.make_archive(zipFile, 'zip', PLUGIN_NAME)
    zipFile+=".zip"
    return zipFile


def getSha1Sum(zipFile):
    info("Generating SHA1")
    sha1 = hashlib.sha1()
    with open(zipFile, 'rb') as f:
        while True:
            data = f.read(65535)
            if not data:
                break
            sha1.update(data)
    return sha1.hexdigest()


def updateRepoXml(repo, version, zipFile, sha1, pluginName=None):
    lines=[]
    updatedVersion=False
    updatedUrl=False
    updatedSha=False
    info("Updating %s" % repo)
    inSection = pluginName is None
    with open(repo, "r") as f:
        lines=f.readlines()
    for i in range(len(lines)):
        if pluginName is not None and '<plugin name="' in lines[i]:
            inSection = pluginName in lines[i]
        if inSection:
            updated = updateLine(lines[i], 'version="', '"', version)
            if updated:
                lines[i]=updated
                updatedVersion=True
            updated = updateLine(lines[i], '<url>', '</url>', releaseUrl(version))
            if updated:
                lines[i]=updated
                updatedUrl=True
            updated = updateLine(lines[i], '<sha>', '</sha>', sha1)
            if updated:
                lines[i]=updated
                updatedSha=True

            if updatedVersion and updatedUrl and updatedSha:
                break

    if not updatedVersion:
        error("Failed to update version in %s" % repo)
    if not updatedUrl:
        error("Failed to url version in %s" % repo)
    if not updatedSha:
        error("Failed to sha version in %s" % repo)
    with open(repo, "w") as f:
        for line in lines:
            f.write(line)


if 1==len(sys.argv):
    usage()

version=sys.argv[1]
if version!="test":
    checkVersion(version)
    checkVersionExists(version)
updateInstallXml(version)

zipFile = createZip(version)
sha1 = getSha1Sum(zipFile)
if version!="test" and os.path.exists(REPO_XML):
    updateRepoXml(REPO_XML, version, zipFile, sha1, PLUGIN_NAME)

