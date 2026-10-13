#!/usr/bin/python3
"""Turn the heartbeat files the 3dcs workflow sends into used allocation hours.

Every 3DCS worker appends timestamps to ~/.3dcs/usage-pending/<node>-<run> (one file per
node and run; the merge adds a -merge file) while it runs, and the workflow's usage_metering
job syncs those files here every minute. This daemon polls the directory: a file that stopped
growing since the previous poll belongs to a finished worker, so its first-to-last timestamp
span is added to the group's used allocation through the platform API and the file is moved
to ~/.3dcs/usage-processed/.

Run it as the metering user of the organization with PW_PLATFORM_HOST and PW_API_KEY (an API
key allowed to update the organization's group allocations) exported:

    ./update-3dcs-usage.py &> ~/.3dcs/update-3dcs-usage.out &

Only one instance runs at a time (file lock). Logs: ~/.3dcs/update-3dcs-usage.log.
"""
import fcntl
import logging
import os
import shutil
import sys
import time
from base64 import b64encode
from datetime import datetime

import requests

# Must be longer than the workers' heartbeat interval (30-60 s) plus the sync interval (60 s)
SLEEP_TIME = 360
REQUEST_TIMEOUT = 60
TIME_FORMAT = "%a %b %d %H:%M:%S %Z %Y"

DCS_DIR = os.path.expanduser("~/.3dcs/")
DCS_PENDING_USAGE_DIR = os.path.join(DCS_DIR, "usage-pending")
DCS_PROCESSED_USAGE_DIR = os.path.join(DCS_DIR, "usage-processed")
LOCK_FILE_PATH = os.path.join(DCS_DIR, "update-3dcs-usage.lock")
os.makedirs(DCS_PENDING_USAGE_DIR, exist_ok=True)
os.makedirs(DCS_PROCESSED_USAGE_DIR, exist_ok=True)

CUSTOMER_ORG_NAME = "honda"
GROUP_NAME = "japan-3dcs-run-hours"
PW_PLATFORM_HOST = os.environ["PW_PLATFORM_HOST"]
HEADERS = {"Authorization": "Basic {}".format(b64encode(os.environ["PW_API_KEY"].encode()).decode())}
GROUPS_URL = f"https://{PW_PLATFORM_HOST}/api/organizations/{CUSTOMER_ORG_NAME}/groups"

# heartbeat file name -> number of lines seen at the previous poll
CONNECTED_WORKERS = {}

logging.basicConfig(
    filename=os.path.join(DCS_DIR, "update-3dcs-usage.log"),
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


def is_running():
    global lock_file
    lock_file = open(LOCK_FILE_PATH, "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except IOError:
        return True


def get_group_info():
    response = requests.get(GROUPS_URL, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    response.raise_for_status()
    for group in response.json():
        if group["name"] == GROUP_NAME:
            return group
    return None


def get_allocation_used(group):
    return group["allocations"].get("used", 0)


def update_group_allocation_used(allocation_used):
    url = f"{GROUPS_URL}/{GROUP_NAME}/allocations"
    payload = {
        "allocation": float(group_info["allocations"]["total"]),
        "allocationUsed": float(allocation_used),
    }
    try:
        response = requests.patch(url, json=payload, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    except requests.RequestException as e:
        logger.error(f"Failed to update the allocation of {GROUP_NAME}: {e}")
        return
    # The API does not always answer with JSON; the status code is what matters
    if response.ok:
        logger.info(f"Updated the allocation of {GROUP_NAME} (HTTP {response.status_code})")
    else:
        logger.error(f"Failed to update the allocation of {GROUP_NAME}: HTTP {response.status_code} {response.text[:300]}")


def list_files_in_directory(directory):
    return [os.path.join(root, name) for root, _, names in os.walk(directory) for name in names]


def calculate_time_difference(file_path):
    """Hours between the first and the last timestamp of a heartbeat file."""
    with open(file_path, "r") as f:
        lines = [line.strip() for line in f if line.strip()]
    if not lines:
        return 0
    first_time = datetime.strptime(lines[0], TIME_FORMAT)
    last_time = datetime.strptime(lines[-1], TIME_FORMAT)
    return (last_time - first_time).total_seconds() / 3600


def move_pending_file_to_processed(pending_file_path):
    file_name = os.path.basename(pending_file_path)
    processed_file_path = os.path.join(DCS_PROCESSED_USAGE_DIR, file_name)
    counter = 1
    while os.path.exists(processed_file_path):
        counter += 1
        processed_file_path = os.path.join(DCS_PROCESSED_USAGE_DIR, f"{file_name}.{counter}")
    if counter > 1:
        logger.warning(f"{file_name} already exists in the processed directory. Renaming to {os.path.basename(processed_file_path)}")
    shutil.move(pending_file_path, processed_file_path)
    logger.info(f"Moved: {file_name} to {processed_file_path}")
    return processed_file_path


def count_lines_in_file(file_path):
    with open(file_path, "r") as f:
        return sum(1 for _ in f)


def process_worker_files(worker_files, allocation_used):
    cached_usage = 0
    for worker_file in worker_files:
        worker_file_name = os.path.basename(worker_file)
        if worker_file_name not in CONNECTED_WORKERS:
            # Seen for the first time: count its lines now and judge it on the next poll
            logger.info(f"Initializing worker file {worker_file_name}.")
            CONNECTED_WORKERS[worker_file_name] = 0

        logger.info(f"Processing file {worker_file}.")
        number_of_lines = count_lines_in_file(worker_file)
        if number_of_lines > CONNECTED_WORKERS[worker_file_name]:
            # Still growing: the worker is running
            CONNECTED_WORKERS[worker_file_name] = number_of_lines
        elif number_of_lines > 1:
            logger.info(f"Worker {worker_file_name} disconnected after {number_of_lines} heartbeats.")
            processed_worker_file = move_pending_file_to_processed(worker_file)
            used_hours = calculate_time_difference(processed_worker_file)
            logger.info(f"Worker file {worker_file_name} used {used_hours} hours.")
            cached_usage += used_hours
            del CONNECTED_WORKERS[worker_file_name]
        else:
            logger.info(f"Worker {worker_file_name} disconnected after {number_of_lines} heartbeats. Assuming 90 seconds connection.")
            move_pending_file_to_processed(worker_file)
            cached_usage += 0.025
            del CONNECTED_WORKERS[worker_file_name]

    if cached_usage > 0:
        allocation_used += cached_usage
        logger.info(f"Updating allocation used to {allocation_used}.")
        update_group_allocation_used(round(allocation_used, 2))
    return allocation_used


logger.info("Running script " + sys.argv[0])

if is_running():
    logger.info("Another instance is already running. Exiting.")
    sys.exit(0)

logger.info("Starting update-3dcs-usage service.")
logger.info("Reading allocation information.")
group_info = get_group_info()
if not group_info:
    logger.error(f"Group {GROUP_NAME} not found in organization {CUSTOMER_ORG_NAME}.")
    raise ValueError(f"Group {GROUP_NAME} not found in organization {CUSTOMER_ORG_NAME}.")

allocation_used = get_allocation_used(group_info)
logger.info("Allocation used: " + str(allocation_used))

try:
    while True:
        time.sleep(SLEEP_TIME)
        try:
            worker_files = list_files_in_directory(DCS_PENDING_USAGE_DIR)
            if worker_files:
                logger.info("Found worker files " + " ".join(worker_files))
                allocation_used = process_worker_files(worker_files, allocation_used)
        except Exception:
            # A malformed file or a failed request must not stop the metering of later runs
            logger.exception("Failed to process the pending usage files; retrying next cycle.")
finally:
    lock_file.close()
    os.remove(LOCK_FILE_PATH)
