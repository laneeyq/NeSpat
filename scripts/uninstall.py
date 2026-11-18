#!/usr/bin/env python3
"""Uninstall preflight and removal under the GUI's existing session.lock.

Uses only Python's standard library and existing macOS tools. No service/helper is
installed. The caller must explicitly request --force-sleep to retain the previous
manual global-reset option; normal uninstall never changes power settings.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass


class UnsafeUninstall(Exception):
    pass


@dataclass(frozen=True)
class Locations:
    apps: tuple
    support: Path
    logs: Path
    agent: Path


def command(args):
    if args[:2] == ['/usr/bin/sudo', '/usr/bin/pmset']:
        # Explicit interactive CLI action: keep the password prompt visible on its terminal.
        return subprocess.run(args, timeout=120)
    return subprocess.run(args, capture_output=True, text=True, timeout=15)


class Uninstaller:
    def __init__(self, locations, run=command):
        self.locations = locations
        self.run = run

    @staticmethod
    def require_owned(path, directory=False):
        if path.is_symlink():
            raise UnsafeUninstall("Символическая ссылка не удаляется: " + str(path))
        info = path.lstat()
        expected = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
        if not expected or info.st_uid != os.getuid():
            raise UnsafeUninstall("Неподтверждённый тип или владелец: " + str(path))
        return (info.st_dev, info.st_ino)

    @contextlib.contextmanager
    def locked(self):
        support = self.locations.support
        if os.path.lexists(support):
            self.require_owned(support, directory=True)
        else:
            support.mkdir(parents=True)
        path = support / 'session.lock'
        fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise UnsafeUninstall("Небезопасный файл блокировки; удаление остановлено.")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise UnsafeUninstall("NeSpat выполняет операцию. Завершите приложение и повторите удаление.")
            yield
        finally:
            os.close(fd)

    def sleep_state(self):
        result = self.run(['/usr/sbin/ioreg', '-r', '-c', 'IOPMrootDomain', '-d', '1'])
        matches = re.findall(r'^\s*"SleepDisabled" = (Yes|No)$', result.stdout, re.M)
        if result.returncode != 0 or len(matches) != 1:
            raise UnsafeUninstall("Состояние сна неизвестно. Приложение и журнал сохранены.")
        return matches[0]

    def require_enabled(self):
        if self.sleep_state() != 'No':
            raise UnsafeUninstall("Запрет сна активен. Сначала восстановите сон в NeSpat; файлы сохранены.")

    def require_stopped(self):
        result = self.run(['/usr/bin/pgrep', '-x', 'NeSpat'])
        if result.returncode != 1:
            raise UnsafeUninstall("NeSpat запущен или отсутствие процесса не подтверждено. Сначала завершите его.")

    def verify_app(self, app):
        root_identity = self.require_owned(app, directory=True)
        for path in (app / 'Contents', app / 'Contents/MacOS'):
            self.require_owned(path, directory=True)
        info_file = app / 'Contents/Info.plist'
        executable = app / 'Contents/MacOS/NeSpat'
        self.require_owned(info_file)
        self.require_owned(executable)
        if any(path.is_symlink() for path in app.rglob('*')):
            raise UnsafeUninstall("Ссылки внутри копии приложения требуют ручной проверки: " + str(app))
        with info_file.open('rb') as stream:
            info = plistlib.load(stream)
        if (info.get('CFBundleIdentifier') != 'local.nespat.app'
                or info.get('CFBundleExecutable') != 'NeSpat'
                or info.get('CFBundlePackageType') != 'APPL'):
            raise UnsafeUninstall("Копия не идентифицирована как NeSpat: " + str(app))
        verified = self.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
        details = self.run(['/usr/bin/codesign', '-d', '--verbose=2', str(app)])
        identifiers = re.findall(r'^Identifier=(.+)$', details.stderr, re.M)
        if verified.returncode or details.returncode or identifiers != ['local.nespat.app']:
            raise UnsafeUninstall("Подпись или идентификатор копии не подтверждены: " + str(app))
        return root_identity

    def verify_journal(self, force):
        path = self.locations.support / 'session.json'
        if not os.path.lexists(path):
            return  # Missing journal is never a substitute for require_enabled().
        self.require_owned(path)
        with path.open() as stream:
            session = json.load(stream)
        if not isinstance(session, dict) or type(session.get('owned')) is not bool:
            raise UnsafeUninstall("Неизвестный формат журнала; файлы сохранены.")
        if session.get('phase') not in (None, 'pending', 'active'):
            raise UnsafeUninstall("Неизвестная фаза сессии; файлы сохранены.")
        if not force and (session['owned'] or session.get('phase') in ('pending', 'active')):
            raise UnsafeUninstall("Сначала разрешите активную/незавершённую сессию в NeSpat; журнал сохранён.")

    def verify_agent(self):
        agent = self.locations.agent
        if not os.path.lexists(agent):
            return False
        self.require_owned(agent)
        with agent.open('rb') as stream:
            info = plistlib.load(stream)
        args = info.get('ProgramArguments')
        if (info.get('Label') != 'local.nespat.watchdog' or not isinstance(args, list)
                or len(args) != 2 or args[1] != '--watchdog' or not isinstance(args[0], str)):
            raise UnsafeUninstall("LaunchAgent не идентифицирован как сторож NeSpat; файлы сохранены.")
        binary = Path(args[0])
        if not binary.is_absolute() or list(binary.parts[-3:]) != ['Contents', 'MacOS', 'NeSpat']:
            raise UnsafeUninstall("Неподтверждённый путь сторожа; файлы сохранены.")
        self.verify_app(binary.parents[2])
        return True

    def uninstall(self, force=False):
        with self.locked():
            # Validate every candidate before removing ANY recovery copy or data.
            apps = [(app, self.verify_app(app)) for app in self.locations.apps if os.path.lexists(app)]
            for path in (self.locations.support, self.locations.logs):
                if os.path.lexists(path):
                    self.require_owned(path, directory=True)
            self.verify_journal(force)
            has_agent = self.verify_agent()
            self.require_stopped()
            observed = self.sleep_state()  # Required even when session.json is absent/owned=false.
            if observed == 'Yes':
                if not force:
                    raise UnsafeUninstall("Запрет сна активен. Восстановите сон в GUI; файлы сохранены.")
                print("Явный сброс глобального запрета сна; это может затронуть другую программу.", flush=True)
                # Existing opt-in functionality. Tests replace this entire command runner.
                result = self.run(['/usr/bin/sudo', '/usr/bin/pmset', '-a', 'disablesleep', '0'])
                if result.returncode:
                    raise UnsafeUninstall("Восстановление не выполнено; приложение и журнал сохранены.")
            self.require_enabled()
            if has_agent:
                label = 'gui/{}/local.nespat.watchdog'.format(os.getuid())
                result = self.run(['/bin/launchctl', 'bootout', label])
                if result.returncode and self.run(['/bin/launchctl', 'print', label]).returncode == 0:
                    raise UnsafeUninstall("Сторож не остановлен; приложение и данные сохранены.")
            self.require_stopped()
            self.require_enabled()
            for app, identity in apps:
                self.require_enabled()
                if self.verify_app(app) != identity:
                    raise UnsafeUninstall("Копия приложения изменилась во время проверки; удаление остановлено.")
                shutil.rmtree(app)
            if has_agent:
                self.locations.agent.unlink()
            if self.locations.logs.exists():
                self.require_enabled()
                shutil.rmtree(self.locations.logs)
            self.require_enabled()
            shutil.rmtree(self.locations.support)  # Recovery journal/lock are removed last.
        print("NeSpat удалён после подтверждения обычного сна и идентичности копий.")


def main():
    parser = argparse.ArgumentParser(description='Безопасное удаление NeSpat после проверки сна и копий приложения.')
    parser.add_argument('--force-sleep', action='store_true', help='явно разрешить глобальный сброс сна с авторизацией')
    args = parser.parse_args()
    home = Path.home()
    repo = Path(__file__).resolve().parent.parent
    locations = Locations(
        (Path('/Applications/NeSpat.app'), home / 'Applications/NeSpat.app', repo / 'build/NeSpat.app'),
        home / 'Library/Application Support/NeSpat', home / 'Library/Logs/NeSpat',
        home / 'Library/LaunchAgents/local.nespat.watchdog.plist'
    )
    try:
        Uninstaller(locations).uninstall(force=args.force_sleep)
    except (UnsafeUninstall, OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print('Удаление остановлено: {}'.format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
