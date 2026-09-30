# Contributing to Media Stack (Ubuntu)

Thanks for helping! This is a small, friendly project.

## Ways to help
- **Report a bug** - open an issue with your Ubuntu version, the flags you used, and what happened. Remove server names, IPs, usernames, keys and passwords from anything you paste.
- **Suggest a feature** - open an issue or start a Discussion.
- **Send a pull request** - fork, create a branch, keep the change focused, and describe how you tested it.
- **Improve the docs** - clearer wording, screenshots and examples are always welcome.

## Dev setup
```
# syntax-check the shell and Python before sending a PR
bash -n install.sh uninstall.sh update.sh tools/update-stats.sh
python3 -m py_compile tools/*.py
```
Read `install.sh` before running it on a real server, and test on a throwaway VM first.

## Ground rules
- Never include real credentials, VPN keys, IP addresses, share names, logs or personal data in issues or PRs.
- Be kind - we follow the [Code of Conduct](CODE_OF_CONDUCT.md).
