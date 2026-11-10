#!/usr/bin/python3
import argparse
import json

import pw_api

# This script runs in the user container, called by the scheduler on the controller
# through the reverse ssh tunnel, and prints the balance in json format. It
# authenticates through the pw CLI (see pw_api.py). The group listing only carries the
# allocations for administrators and group members, which the workspace's identity is
# not, so every matching group is fetched individually: its detail does include them

# FIXME: Get from license server
GT_PRODUCTS = ['gtlinear', 'gtpowerx', 'gtsuite', 'gtautoliononed', 'gtpowerxrt', 'gtxchem', 'gtfemag', 'gtautothreedflow', 'gtautomation', 'cosimthermal', 'gtadvancedcombustion', 'gtautolionthreed', 'gtjmagmachine', 'gtthreedmbd', 'gtthreedmbdadvancedtribology', 'gtthreedmbdmachinery', 'gtthreedmbdvehicledynamics']

def check_group_existence(group_names, existing_groups):
    """Check if all group names exist in the retrieved groups."""
    for group_name in group_names:
        if group_name not in existing_groups:
            raise ValueError(f"Group '{group_name}' not found.")


def get_balance(group_names, groups):
    balance = {gt_product: 0 for gt_product in GT_PRODUCTS}

    for group in groups:
        if group['name'] in group_names:
            product_name = group['name'].split('-')[-1]
            allocations = group.get('allocations') or {}
            allocation_used = allocations.get('used') or 0
            allocation_total = allocations.get('total') or 0
            balance[product_name] = allocation_total-allocation_used 
    
    print(json.dumps(balance), flush = True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Process customer_name, customer_org_id and customer_org_name')
    parser.add_argument('--customer_name', type=str, help='Name of the customer')
    parser.add_argument('--customer_org_id', type=str, help='Organization ID of the customer')
    parser.add_argument('--customer_org_name', type=str, help='Organization name of the customer')
    args = parser.parse_args()
    # Customers of the PW managed solution all share the same user account in PW. 
    # Therefore, the customer name is used to identify each customer. 
    # The customer name is used to create groups with license hour allocations
    # The names of these groups are in the format <customer_name>-<gt_product_name>
    customer_name = args.customer_name
    # Org ID obtained from here https://cloud.parallel.works/api/v2/organization
    # Users of the PW managed solution will all be under the same organization
    customer_org_id = args.customer_org_id 
    customer_org_name = args.customer_org_name 

    group_names = [f'{customer_name}-{gt_prod}' for gt_prod in GT_PRODUCTS]

    all_groups = pw_api.get(f'organizations/{customer_org_name}/groups', {'organization': customer_org_id})
    existing_groups = [group['name'] for group in all_groups]

    #check_group_existence(group_names, existing_groups)

    groups = [
        pw_api.get(f'organizations/{customer_org_name}/groups/{group_name}')
        for group_name in group_names if group_name in existing_groups
    ]

    get_balance(group_names, groups)
