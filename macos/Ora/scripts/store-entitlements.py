"""Reject development/iOS/wrong-app profiles before App Store signing."""
import datetime
import plistlib
import sys

profile_path, base_path, output_path = sys.argv[1:]
with open(profile_path, "rb") as stream:
    profile = plistlib.load(stream)
with open(base_path, "rb") as stream:
    entitlements = plistlib.load(stream)
team = profile.get("TeamIdentifier", [None])[0]
allowed = profile.get("Entitlements", {})
identifier = allowed.get("com.apple.application-identifier", allowed.get("application-identifier"))
if not team or identifier != f"{team}.com.wangzhangwu.ora":
    sys.exit("The provisioning profile must match the production Ora bundle ID.")
if not set(profile.get("Platform", [])) & {"OSX", "macOS"}:
    sys.exit("A macOS provisioning profile is required.")
if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices") or allowed.get("get-task-allow") or allowed.get("com.apple.security.get-task-allow"):
    sys.exit("A distribution profile for the Mac App Store is required.")
expiry = profile.get("ExpirationDate")
if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("The provisioning profile is expired.")
entitlements["com.apple.application-identifier"] = identifier
entitlements["com.apple.developer.team-identifier"] = team
entitlements["keychain-access-groups"] = [identifier]
with open(output_path, "wb") as stream:
    plistlib.dump(entitlements, stream)
