#!/usr/bin/env python3
"""Rewrite the embedded bundle id inside the fake provisioning profiles and
re-sign them with the SelfSigned fake certificate.

The committed fake profiles are tied to `ph.telegra.Telegraph`. When the app is
built with a different bundle id, `copy_profiles_from_directory` (see
BuildConfiguration.py) only picks up profiles whose embedded
`application-identifier` starts with `<team_id>.<bundle_id>`, and rules_apple
requires the profile entitlements to be a superset of the app entitlements
(app group `group.<bundle_id>`, iCloud container `iCloud.<bundle_id>`, ...).

This script decodes each profile, textually replaces the old bundle id with the
new one across every entitlement (application-identifier, app groups, iCloud /
ubiquity containers, Name, ...), swaps in the fake developer certificate and
re-signs it in place using macOS `security cms`. It reuses the temp-keychain and
certificate helpers from GenerateProfiles.py so the signing path is identical to
the one that produced the original fake profiles.

Runs on macOS (needs `security`/`plutil`). Invoked from CI before the build.
"""

import os
import sys
import tempfile
import argparse

from BuildEnvironment import run_executable_with_output
from GenerateProfiles import (
    setup_temp_keychain,
    cleanup_temp_keychain,
    get_signing_identity_from_p12,
)


def rewrite_profile(source, old_bundle_id, new_bundle_id, signing_identity, keychain_name):
    # Decode the CMS-wrapped profile to its plist payload.
    parsed_plist = run_executable_with_output('security', arguments=['cms', '-D', '-i', source], check_result=True)

    parsed_plist_file = tempfile.mktemp()
    with open(parsed_plist_file, 'w+') as file:
        file.write(parsed_plist)

    # Normalize to xml1 so the textual replacement is well-defined.
    run_executable_with_output('plutil', arguments=['-convert', 'xml1', parsed_plist_file], check_result=True)

    with open(parsed_plist_file, 'r') as file:
        contents = file.read()

    if old_bundle_id not in contents:
        print('  warning: {} not present in {}'.format(old_bundle_id, source))
    contents = contents.replace(old_bundle_id, new_bundle_id)

    with open(parsed_plist_file, 'w') as file:
        file.write(contents)

    # NOTE: do NOT touch DeveloperCertificates. The committed fake profiles are
    # already signed by (and carry) the SelfSigned cert that ImportCertificates
    # loads into the build keychain, so codesign already finds a matching
    # identity. Re-inserting the cert here previously broke that match
    # ("Unable to find an identity ... matching the ones in <profile>").

    # Drop the DER signature blob; it embeds a stale copy of the entitlements
    # (with the old bundle id) that codesign would otherwise read instead of the
    # rewritten plist. It is re-created by the CMS signature below.
    run_executable_with_output('plutil', arguments=['-remove', 'DER-Encoded-Profile', parsed_plist_file], check_result=False)

    # Re-sign in place with the fake certificate (same identity that already
    # signs the profile), so it stays a valid CMS-wrapped .mobileprovision.
    run_executable_with_output('security', arguments=[
        'cms', '-S', '-k', keychain_name, '-N', signing_identity, '-i', parsed_plist_file, '-o', source
    ], check_result=True)

    os.unlink(parsed_plist_file)


def rewrite_profiles(profiles_path, certs_path, old_bundle_id, new_bundle_id):
    p12_path = os.path.join(certs_path, 'SelfSigned.p12')
    if not os.path.exists(p12_path):
        print('{} does not exist'.format(p12_path))
        sys.exit(1)

    p12_password = ''  # fake-codesigning uses an empty password
    signing_identity = get_signing_identity_from_p12(p12_path, p12_password)
    if not signing_identity:
        print('Could not extract signing identity from {}'.format(p12_path))
        sys.exit(1)

    print('Rewriting {} -> {}'.format(old_bundle_id, new_bundle_id))
    print('Using signing identity: {}'.format(signing_identity))

    keychain_name = setup_temp_keychain(p12_path, p12_password)
    try:
        count = 0
        for file_name in sorted(os.listdir(profiles_path)):
            if not file_name.endswith('.mobileprovision'):
                continue
            print('Processing {}'.format(file_name))
            rewrite_profile(
                source=os.path.join(profiles_path, file_name),
                old_bundle_id=old_bundle_id,
                new_bundle_id=new_bundle_id,
                signing_identity=signing_identity,
                keychain_name=keychain_name,
            )
            count += 1
        print('Done. Rewrote {} profiles.'.format(count))
    finally:
        cleanup_temp_keychain(keychain_name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Rewrite the bundle id in fake provisioning profiles and re-sign them.')
    parser.add_argument('--profilesPath', required=True, help='Directory containing the .mobileprovision files (rewritten in place).')
    parser.add_argument('--certsPath', required=True, help='Directory containing SelfSigned.p12.')
    parser.add_argument('--oldBundleId', required=True, help='Bundle id currently embedded in the profiles.')
    parser.add_argument('--newBundleId', required=True, help='Bundle id to write into the profiles.')
    args = parser.parse_args()

    rewrite_profiles(
        profiles_path=args.profilesPath,
        certs_path=args.certsPath,
        old_bundle_id=args.oldBundleId,
        new_bundle_id=args.newBundleId,
    )
