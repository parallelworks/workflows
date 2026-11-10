import json
import sys
import os
import requests
from copy import deepcopy

def read_sched_prop_file(sched_prop_file):
    sched_propf_info = {}
    sched_propf_info['max-licenses'] = {}
    sched_propf_info['permitted-licenses'] = []
    with open(sched_prop_file, 'r') as fp:
        Lines = fp.readlines()
        for line in Lines:
            if line.startswith('#'):
                continue

            if 'GTDistributed.scheduler.max-licenses' in line:
                pname = line.split('.')[3].split('=')[0].rstrip().lower().replace(' ','')
                pval = line.split('=')[1].rstrip().replace(' ','')
                sched_propf_info['max-licenses'][pname] = pval
            elif 'GTDistributed.scheduler.validation.permitted-licenses' in line:
                sched_propf_info['permitted-licenses'] = [pname.rstrip().lower().replace(' ','') for pname in line.split('=')[1].split(',')]

    return sched_propf_info


def write_sched_prop_file(sched_prop_file, sched_propf_info):
    fp = open(sched_prop_file, 'r')
    sched_propf_lines = fp.readlines()
    fp.close()
    with open(sched_prop_file, 'w') as fp:
        for line in sched_propf_lines:
            if line.startswith('#'):
                fp.write(line)
            elif 'GTDistributed.scheduler' not in line:
                fp.write(line)
            elif 'GTDistributed.scheduler.max-licenses' in line:
                pname = line.split('.')[3].split('=')[0].rstrip().lower()
                line_start = line.split('=')[0]
                fp.write(line_start + ' = ' + sched_propf_info['max-licenses'][pname] + '\n')
                sched_propf_info['max-licenses'][pname] = 'saved'
            elif 'GTDistributed.scheduler.validation.permitted-licenses' in line:
                permitted_licenses = [pl.upper() for pl in sched_propf_info['permitted-licenses']]
                fp.write('GTDistributed.scheduler.validation.permitted-licenses = ' + ','.join(permitted_licenses) + '\n')
                sched_propf_info['permitted-licenses'] = 'saved'
            else:
                fp.write(line)

        # Check that all properties file info were written!
        for pname, pval in sched_propf_info['max-licenses'].items():
            if pval != 'saved':
                fp.write('GTDistributed.scheduler.max-licenses.' + pname.upper() + ' = ' + pval + '\n')
        if sched_propf_info['permitted-licenses'] != 'saved':
            permitted_licenses = [pl.upper() for pl in sched_propf_info['permitted-licenses']]
            if len(permitted_licenses) == 1:
                permitted_licenses = permitted_licenses[0]
            else:
                permitted_licenses = ','.join(permitted_licenses)
            fp.write('GTDistributed.scheduler.validation.permitted-licenses = ' + permitted_licenses + '\n')


def check_balance(balance, sched_prop_file):
    sched_propf_info = read_sched_prop_file(sched_prop_file)
    sched_propf_info_new = deepcopy(sched_propf_info)
    warnings = []
    for pname, premain in balance.items():
        # - Are we going to have hard/soft limits per product?
        if float(premain) <= 0: # FIXME: Should be less than the soft or hard limits?
            warnings.append("No more core-hours left of product {}!".format(pname))
            warnings.append("Submission of new packets will be inhibited for this product.")

            sched_propf_info_new['max-licenses'][pname] = '0'
            if pname in sched_propf_info['permitted-licenses']:
                sched_propf_info_new['permitted-licenses'].remove(pname)
        else:
            sched_propf_info_new['max-licenses'][pname] = '-1'
            if pname not in sched_propf_info['permitted-licenses']:
                sched_propf_info_new['permitted-licenses'].append(pname)

    if sched_propf_info_new != sched_propf_info:
        [print(warning) for warning in warnings]
        write_sched_prop_file(sched_prop_file, sched_propf_info_new)

def create_inhibit_jobs_file():
    # Create the INHIBIT_JOBS file
    with open("INHIBIT_JOBS", "w") as f:
        pass


if __name__ == '__main__':
    sched_prop_file = sys.argv[1]

    if not os.path.isfile('balance.json'):
        raise FileNotFoundError("balance.json file not found.")

    if not os.path.isfile(sched_prop_file):
        raise FileNotFoundError(f"Schedule property file {sched_prop_file} not found.")

    with open('balance.json') as balance_json:
        balance = json.load(balance_json)

    # Check if balance is zero for all products and write the INHIBIT_JOBS file
    # to prevent the workflow from submitting additional jobs
    if all(value == 0 for value in balance.values()):
        create_inhibit_jobs_file()
    elif os.path.isfile("INHIBIT_JOBS"):
        # Balance was restored; remove the flag so job submission resumes
        os.remove("INHIBIT_JOBS")

    check_balance(balance, sched_prop_file)
