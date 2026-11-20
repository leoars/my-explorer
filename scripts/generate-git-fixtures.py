#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create isolated repositories for the native GUI smoke; no account or network access."""
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
root.mkdir()
repo = root / 'Git project'
repo.mkdir()
env = dict(os.environ)
for key in list(env):
    if key.startswith('GIT_'):
        env.pop(key)
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')

def git(*args, expected=0):
    result = subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
        '-c', 'user.name=My Explorer Smoke', '-c', 'user.email=smoke@example.invalid', '-C', str(repo), *args],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    if result.returncode != expected:
        raise RuntimeError(f'Git fixture failed: {args[0]} ({result.returncode})')

git('init', '-q', '-b', 'main')
for name in ['clean.txt', 'modified.txt', 'staged.txt', 'deleted.txt', 'conflict.txt', 'old-name.txt']:
    (repo / name).write_text('initial\n')
(repo / 'Nested').mkdir()
(repo / 'Nested' / 'changed.txt').write_text('initial\n')
(repo / '.gitignore').write_text('ignored.log\ncache/\n')
git('add', '.')
git('commit', '-qm', 'Base fixture')
git('worktree', 'add', '-q', '-b', 'feature/ui', str(root / 'Linked worktree'))
git('checkout', '-qb', 'other')
(repo / 'conflict.txt').write_text('other branch\n')
git('commit', '-qam', 'Other fixture')
git('checkout', '-q', 'main')
(repo / 'conflict.txt').write_text('main branch\n')
git('commit', '-qam', 'Main fixture')
git('merge', '--no-edit', 'other', expected=1)
(repo / 'modified.txt').write_text('working changes\n')
(repo / 'staged.txt').write_text('staged changes\n')
git('add', 'staged.txt')
git('mv', 'old-name.txt', 'renamed 日本語.txt')
(repo / 'deleted.txt').unlink()
(repo / 'Nested' / 'changed.txt').write_text('nested changes\n')
(repo / 'new file.txt').write_text('untracked\n')
(repo / 'ignored.log').write_text('ignored\n')
(repo / 'cache').mkdir()
(repo / 'cache' / 'ignored.txt').write_text('ignored\n')
(root / 'Linked worktree' / 'new.txt').write_text('worktree change\n')
print('Generated isolated Git and linked-worktree fixtures')
