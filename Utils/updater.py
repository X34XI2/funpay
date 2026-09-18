"""
Проверка на обновления.
"""
import time
from logging import getLogger
from locales.localizer import Localizer
import requests
import os
import zipfile
import shutil
import json

logger = getLogger("FPC.update_checker")
localizer = Localizer()
_ = localizer.translate

HEADERS = {
    "accept": "application/vnd.github+json"
}


class Release:
    """
    Класс, описывающий релиз.
    """

    def __init__(self, name: str, description: str, sources_link: str):
        """
        :param name: название релиза.
        :param description: описание релиза (список изменений).
        :param sources_link: ссылка на архив с исходниками.
        """
        self.name = name
        self.description = description
        self.sources_link = sources_link


# Получение данных о новом релизе
def get_latest_releases(limit: int = 10) -> list[Release] | None:
    """
    Получает последние релизы репозитория, отсортированные от самого свежего к старому.

    Сортировка идёт по дате публикации (published_at), а не по порядку страниц GitHub:
    в форке теги расставлены не в хронологическом порядке, поэтому позиция в списке
    тегов ничего не значит.

    :param limit: сколько последних релизов вернуть.

    :return: список релизов или None, если получить данные не удалось.
    """
    try:
        response = requests.get("https://api.github.com/repos/X34XI2/funpay/releases?per_page=100",
                                headers=HEADERS)
        if response.status_code != 200:
            logger.debug(f"Update status code is {response.status_code}!")
            return None

        releases_raw = response.json()
        if not releases_raw:
            logger.debug("Releases list is empty!")
            return None

        def published_at(release: dict) -> str:
            # пустая дата уводится в начало, чтобы не считаться свежей
            return release.get("published_at") or release.get("created_at") or ""

        releases_raw.sort(key=published_at, reverse=True)

        result = []
        for el in releases_raw[:limit]:
            name = el.get("tag_name") or el.get("name") or "?"
            description = el.get("body") or ""
            sources = el.get("zipball_url")
            if not sources:
                continue
            result.append(Release(name, description, sources))
        return result or None
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return None


# Получение данных о новом релизе
def get_new_releases(current_tag) -> int | list[Release]:
    """
    Проверяет на наличие обновлений.

    :param current_tag: тег текущей версии (используется только для информации).

    :return: список объектов релизов или код ошибки:
        1 - произошла ошибка при получении списка релизов.
        2 - обновлений нет (текущий релиз - самый свежий).
        3 - не удалось получить данные о релизе.
    """
    releases = get_latest_releases()
    if releases is None:
        return 1

    # Тег текущей версии в форке не совпадает с тегами релизов (в коде "v0.1.17.8",
    # в репозитории - "1"/"2"/"update1"), поэтому ищем релиз, у которого имя/тег
    # совпадает с текущей версией. Если не нашли - считаем, что стоит не релизная
    # сборка, и предлагаем просто самый свежий релиз.
    if current_tag and any(r.name == current_tag.lstrip("v") or r.name == current_tag for r in releases):
        return 2

    return releases[:1]


#  Загрузка нового релиза
def download_zip(url: str) -> int:
    """
    Загружает zip архив с обновлением в файл storage/cache/update.zip.

    :param url: ссылка на zip архив.

    :return: 0, если архив с обновлением загружен, иначе - 1.
    """
    try:
        with requests.get(url, stream=True) as r:
            r.raise_for_status()
            with open("storage/cache/update.zip", 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
        return 0
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return 1


def extract_update_archive() -> str | int:
    """
    Разархивирует скачанный update.zip.

    :return: название папки с обновлением (storage/cache/update/<папка с обновлением>) или 1, если произошла ошибка.
    """
    try:
        if os.path.exists("storage/cache/update/"):
            shutil.rmtree("storage/cache/update/", ignore_errors=True)
        os.makedirs("storage/cache/update")

        with zipfile.ZipFile("storage/cache/update.zip", "r") as zip:
            folder_name = zip.filelist[0].filename
            zip.extractall("storage/cache/update/")
        return folder_name
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return 1


def zipdir(path, zip_obj):
    """
    Рекурсивно архивирует папку.

    :param path: путь до папки.
    :param zip_obj: объект zip архива.
    """
    for root, dirs, files in os.walk(path):
        if os.path.basename(root) == "__pycache__":
            continue
        for file in files:
            zip_obj.write(os.path.join(root, file),
                          os.path.relpath(os.path.join(root, file),
                                          os.path.join(path, '..')))


def create_backup() -> int:
    """
    Создает резервную копию с папками storage и configs.

    :return: 0, если бэкап создан успешно, иначе - 1.
    """
    try:
        with zipfile.ZipFile("backup.zip", "w") as zip:
            zipdir("storage", zip)
            zipdir("configs", zip)
            zipdir("plugins", zip)
        return 0
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return 1


def extract_backup_archive() -> bool:
    """
    Разархивирует скачанный backup.zip. в storage/cache/backup/

    :return: True, если разархивировано. False в случае ошибок.
    """
    try:
        if os.path.exists("storage/cache/backup/"):
            shutil.rmtree("storage/cache/backup/", ignore_errors=True)
        os.makedirs("storage/cache/backup")

        with zipfile.ZipFile("storage/cache/backup.zip", "r") as zip:
            zip.extractall("storage/cache/backup/")
        return True
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return False


def install_release(folder_name: str) -> int:
    """
    Устанавливает обновление.

    :param folder_name: название папки со скачанным обновлением в storage/cache/update
    :return: 0, если обновление установлено.
        1 - произошла непредвиденная ошибка.
        2 - папка с обновлением отсутствует.
    """
    try:
        release_folder = os.path.join("storage/cache/update", folder_name)
        if not os.path.exists(release_folder):
            return 2

        if os.path.exists(os.path.join(release_folder, "delete.json")):
            with open(os.path.join(release_folder, "delete.json"), "r", encoding="utf-8") as f:
                data = json.loads(f.read())
                for i in data:
                    if not os.path.exists(i):
                        continue
                    if os.path.isfile(i):
                        os.remove(i)
                    else:
                        shutil.rmtree(i, ignore_errors=True)

        for i in os.listdir(release_folder):
            if i == "delete.json":
                continue

            source = os.path.join(release_folder, i)
            if source.endswith(".exe"):
                if not os.path.exists("update"):
                    os.mkdir("update")
                shutil.copy2(source, os.path.join("update", i))
                continue

            if os.path.isfile(source):
                shutil.copy2(source, i)
            else:
                shutil.copytree(source, os.path.join(".", i), dirs_exist_ok=True)
        return 0
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return 1


def install_backup() -> bool:
    """
    Устанавливает бэкап.
    """
    try:
        backup_folder = "storage/cache/backup"
        if not os.path.exists(backup_folder):
            return False

        for i in os.listdir(backup_folder):
            source = os.path.join(backup_folder, i)

            if os.path.isfile(source):
                shutil.copy2(source, i)
            else:
                shutil.copytree(source, os.path.join(".", i), dirs_exist_ok=True)
        return True
    except:
        logger.debug("TRACEBACK", exc_info=True)
        return False
