git config --local filter.sops.clean "sops encrypt --filename-override %f /dev/stdin"
git config --local filter.sops.smudge "sops decrypt --filename-override %f /dev/stdin"
git config --local filter.sops.required true
