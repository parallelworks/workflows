import json
import sys
import os
from copy import deepcopy
import xml.etree.ElementTree as ET
import argparse

def joblog2dict(job_log):
    job_log_f = open(job_log, "r")
    job_log_lines = [jl.replace("\n","") for jl in job_log_f.readlines()]
    job_log_f.close()

    job_name = job_log_lines[0].split("\t")[1].split(' ')[0]
    sim_packet_names = []
    merge_pname = None
    #job_dict = {"status": None, "run_time": 0, "split_status": None,
    #            "merge_status": None, "sim_packets": None}
    job_dict = {"status": None, "sim_packets": None}

    # Events are logged to the job.log
    for el in job_log_lines: # el: event line
        # Type of event
        # - start, submitted, finish, produced, status and has (has x results)
        etype = el.split("\t")[1].split(' ')[1]

        # Script only logs status (for metering) and produced (for counting demand) events:
        if etype == "status":
            # Only changes of status are reported!
            status = el.split("\t")[-1].split(' ')[-1]
            # Subject of the status event (job, packet, split or merge)
            esubject = el.split("\t")[1].split(' ')[0]
            packet_name = esubject.split("-")[-1]
 
            # Subject is Job
            if esubject == job_name:
                job_dict["status"] = status

            # Subject is a sim packet
            elif packet_name in sim_packet_names:
                job_dict["sim_packets"][packet_name]["status"] = status

        elif etype == "produced":
            nsp = int(el.split("\t")[1].split(' ')[2])
            merge_pname = str(nsp+1).zfill(4)
            # Initialize sim_packets dictionary
            sim_packet_names = [str(pn).zfill(4) for pn in range(1, nsp + 1)]
            job_dict["sim_packets"] = dict.fromkeys(sim_packet_names, None)
            for pn in sim_packet_names:
                #job_dict["sim_packets"][pn] = {"status": None, "start_time": None, "run_time": 0}
                job_dict["sim_packets"][pn] = {"status": None}

    return job_dict


# Convert info from webapp to job log
def webapp2dict(webapp_xml):
    jobs_dict = {}
    if not os.path.isfile(webapp_xml):
        return 0
    tree = ET.parse(webapp_xml)
    root = tree.getroot()
    for job in root.iter('job'):
        for name in job.iter("name"):
            job_name = name.text
        job_id = job.attrib["id"]

        jobs_dict[job_id] = {
            "Name": job_name,
            "model.product": None,
            "solver.parallel-cpu": 1,
            "scheduler.max-licenses-per-batch": None,
            "scheduler.max-cores-per-batch": None
        }
        for prop in job.iter('property'):
            if prop.attrib["key"] == "model.product":
                jobs_dict[job_id]["model.product"] = prop.text

            if prop.attrib["key"] == "solver.parallel-cpu":
                jobs_dict[job_id]["solver.parallel-cpu"] = int(prop.text)

            if prop.attrib["key"] == "solver.parallel-cpu-mkl":
                jobs_dict[job_id]["solver.parallel-cpu-mkl"] = int(prop.text)

            if prop.attrib["key"] == "scheduler.max-licenses-per-batch":
                jobs_dict[job_id]["scheduler.max-licenses-per-batch"] = int(prop.text)

            if prop.attrib["key"] == "scheduler.max-cores-per-batch":
                jobs_dict[job_id]["scheduler.max-cores-per-batch"] = int(prop.text)

    return jobs_dict


def get_running_and_queued(job_dict):
    rqc = 0
    rqc_status = ["QUEUED", "SUBMITTING", "SUBMITTED", "RUNNING"]
    if hasattr(job_dict["sim_packets"], 'items'):
        for key,value in job_dict["sim_packets"].items():
            status = value["status"]
            if any([st == status for st in rqc_status]):
                rqc += 1
    return rqc

# Counts current core demand by looking are the running + pending packets
# Considers the license per job and
# FIXME: Cannot avoid requesting cores that don't have a license
# product_available --> To know remaining product runtime
# product_limits    --> To know total product licenses
# FIXME: Cannot use model.product!
def count_core_demand(active_jobs, allow_ps):
    core_demand = 0
    if not active_jobs:
        return 0

    for job,job_info in active_jobs.items():

        # Ignore cases with parallel-cpu > 1 if customer is not using their own resource:
        # FIXME: Only if user is running in PW resources!
        if job_info["solver.parallel-cpu"] > 1 and allow_ps == 'false':
            msg = 'WARNING: DO NOT USE THE PARALLEL SOLVER WHEN RUNNING IN PW CLOUD RESOURCES!!!'
            print(msg, flush = True)
            msg = 'GT job with solver.parallel-cpu > 1 was submitted! This is not permitted! @avidalto'
            continue

        # Simulation packets running and queued
        job_packets = get_running_and_queued(job_info)
        # Set defaults:
        job_lic = job_packets

        if job_info["scheduler.max-licenses-per-batch"] is None:
            job_lic_demand = job_lic
            job_packet_demand = job_packets

        else: # Max job licenses defined
            job_lic_demand = min(job_lic, job_info["scheduler.max-licenses-per-batch"])
            job_packet_demand = min(job_packets, job_lic_demand)


        if job_info["scheduler.max-cores-per-batch"] is None:
            job_core_demand = job_info["solver.parallel-cpu"] * job_packet_demand
        else: # Max job cores defined
            job_core_demand = min(job_info["solver.parallel-cpu"] * job_packet_demand, job_info["scheduler.max-cores-per-batch"])
            job_lic_demand = int(job_core_demand / job_info["solver.parallel-cpu"])

        core_demand += job_core_demand
    return core_demand


# Returns a dictionary with job information extracted from the job log
# Merges information from the webapp and the job.log
# Active jobs are jobs that are not completed
# Active jobs SHOULD appear in the webapp_xml
def get_active_jobs(webapp_xml, sched_work_dir):
    jobs_dir = sched_work_dir + "gtdistd/jobs"
    jobs_dict = webapp2dict(webapp_xml)
    active_jobs = deepcopy(jobs_dict)
    for job in jobs_dict.keys():
        job_log = jobs_dir + "/" + job + "/job.log"
        if os.path.isfile(job_log):
            active_jobs[job].update(joblog2dict(job_log))
        else: # If job has been killed by deleting its job_dir --> No longer active
            del active_jobs[job]
    return active_jobs

# Sample active_jobs:
# {'JMYZQ7': {'Name': '1cyl_3','model.product': 'GTsuiteMP','solver.parallel-cpu': 1, 'scheduler.max-licenses-per-batch': None, 'scheduler.max-cores-per-batch': None, 'status': 'QUEUED','sim_packets': {
#    '0001': {'status': 'QUEUED'},'0002': {'status': 'QUEUED'},'0003': {'status': 'QUEUED'},'0004': {'status': 'QUEUED'}}}
def remove_jobs_with_no_balance(active_jobs, balance):
    mapping = {
        'gtdrive': 'gtsuite',
        'gtpower': 'gtsuite',
        'gtpowerlab': 'gtsuite',
        'gtsuite': 'gtsuite',
        'gtsuitemp': 'gtsuite',
        'xlink': 'gtsuite',
        'gtautoliononed': 'gtautoliononed',
        'gtautolion': 'gtautoliononed',
        'gtpowerxrt': 'gtpowerxrt',
        'gtautomation': 'gtautomation',
        'gtprocessmap': 'gtautomation',
        'optimizer': '',
        'cosimthermal': 'cosimthermal',
        'gtadvancedcombustion': 'gtadvancedcombustion',
        'gtautolionthreed': 'gtautolionthreed',
        'gtautolion3d':  'gtautolionthreed',
        'gtlinear': 'gtlinear',
        'gtjmagmachine': 'gtjmagmachine',
        'gtthreedmbd': 'gtthreedmbd',
        'gtthreedmbdadvancedtribology': 'gtthreedmbdadvancedtribology',
        'gtthreedmbdmachinery': 'gtthreedmbdmachinery',
        'gtthreedmbdvehicledynamics': 'gtthreedmbdvehicledynamics',
        'gtxchem': 'gtxchem',
        'gtfemag': 'gtfemag',
        'gtautothreedflow': 'gtautothreedflow'
    }

    active_jobs_with_balance = deepcopy(active_jobs)

    for job, job_info in active_jobs.items():
        job_license = mapping[
            job_info['model.product'].lower()
        ]

        if not job_license:
            # In some cases the job license is unkown at this point
            continue
        elif job_license not in balance:
            print(f'Warning: Removing job with license {job_license} not present in balance\n', job_info, balance, file=sys.stderr, flush = True)
            del active_jobs_with_balance[job]
        elif balance[job_license] <= 0:
            print(f'Warning: Removing job with license {job_license} and no balance\n', job_info, balance, file=sys.stderr, flush = True)
            del active_jobs_with_balance[job]

    return active_jobs_with_balance

def remove_jobs_with_incompatible_version(active_jobs, version):
    active_jobs_with_compatible_version = deepcopy(active_jobs)
    sched_version = int(version.replace('v',''))
    for job, job_info in active_jobs.items():
        job_version = job_info['model.version']
        try:
            job_version = int(job_version)
        except:
            print('Could not convert job_version {} to integer'.format(job_version), flush = True)
            del active_jobs_with_compatible_version[job]
            continue

        if job_version > sched_version:
            del active_jobs_with_compatible_version[job]

    return active_jobs_with_compatible_version

# Update job records JSON file with active jobs info
def update_job_records(job_records, active_jobs):
    if job_records:
        for job,job_info in active_jobs.items():
            job_records[job] = job_info
    else:
        job_records = deepcopy(active_jobs)
    return job_records


    if os.path.isfile(job_records_json):
        with open(job_records_json, 'r') as json_file:
            job_records = json.load(json_file)

        for job,job_info in active_jobs.items():
            job_records[job] = job_info

        with open(job_records_json, 'w') as json_file:
            json.dump(job_records, json_file, indent = 4)
    else:
         with open(job_records_json, 'w') as json_file:
            json.dump(active_jobs, json_file, indent = 4)


if __name__ == '__main__':
    # Create argument parser
    parser = argparse.ArgumentParser(description='Process command line arguments')

    # Add arguments
    parser.add_argument('--webapp_xml', type=str, help='Path to webapp XML file')
    parser.add_argument('--sched_work_dir', type=str, help='Path to scheduler work directory')
    parser.add_argument('--balance_json', type=str, help='Path to balance JSON file')
    parser.add_argument('--allow_ps', type=bool, help='Boolean indicating whether to allow PS')
    
    args = parser.parse_args()

    with open(args.balance_json) as balance_json:
        balance = json.load(balance_json)

    active_jobs = get_active_jobs(args.webapp_xml, args.sched_work_dir)
    active_jobs = remove_jobs_with_no_balance(active_jobs, balance)
    core_demand = count_core_demand(active_jobs, args.allow_ps)
    print(core_demand, flush=True)