import argparse
import json
import os
import time
import requests
import sys
import re

parser = argparse.ArgumentParser()
parser.add_argument(
    '--output_dir',
    required = True,
    help = 'Output directory',
    type = str
)
parser.add_argument(
    '--gvcf_dir',
    required = True,
    help = 'Dir containing gvcf files from which to extract variants',
    type = str
)
parser.add_argument(
    '--ref_prefix',
    required = True,
    help = 'Prefix for reference files',
    type = str
)
parser.add_argument(
    '--sequencing_provider',
    help = 'Sequencing provider',
    default = 'revvity',
    type = str,
    choices = ['revvity', 'genedx']
)
parser.add_argument(
    '--argo_api_url',
    help = 'URL for ARGO API',
    default = 'http://argo-early-check-rs-1-server:2746/api/v1/workflows/early-check-rs-1',
    type = str
)
parser.add_argument(
    '--simultaneous_jobs',
    help = '# of simultaneous jobs',
    default = 50,
    type = int
)
parser.add_argument(
    '--include_homozygous_ref',
    help = 'Include positions that are homozygous reference',
    default = 0,
    type = int
)
parser.add_argument(
    '--filter_by_qual',
    help = 'Limit extraction to variants with QUAL=PASS',
    default = 0,
    type = int
)
parser.add_argument(
    '--filter_by_gq',
    help = 'Filter variatns by GQ',
    default = 0,
    type = int
)
parser.add_argument(
    '--hom_gq_threshold',
    help = 'GQ threshold for homozygous variants',
    default = 99,
    type = int
)
parser.add_argument(
    '--het_gq_threshold',
    help = 'GQ threshold for heterozygous variants',
    default = 48,
    type = int
)
parser.add_argument(
    '--ancestry_pop_type',
    help = '1000 Genomes population type',
    default = 'SUPERPOP',
    choices = ['SUPERPOP', 'POP']
)
parser.add_argument(
    '--ancestries_to_include',
    help = '1000 Genomes ancestries to include',
    default = 'AFR,AMR,EAS,EUR,SAS',
    type = str
)
parser.add_argument(
    '--std_dev_cutoff',
    help = 'Standard deviation cutoff for ancestry',
    default = 3,
    type = int
)
parser.add_argument(
    '--scale_to_ref',
    help = 'Scale Mahalanobis distance to reference for SD cutoffs rather than within scaling within dataset',
    default = 1,
    type = int
)
parser.add_argument(
    '--workflow_template',
    help = 'Workflow template to use',
    default = 'ancestry',
    type = str
)
parser.add_argument(
    '--entrypoint',
    help = 'Entrypoint to use',
    default = 'munge-extract-ref-variants-from-gvcf',
    choices = ['munge-extract-ref-variants-from-gvcf', 'ancestry-from-gvcf'],
    type = str
)
args = parser.parse_args()

# Function to get the number of running workflows
def get_running_workflows():
    response = requests.get(args.argo_api_url)
    data = response.json()
    if 'items' not in data or data['items'] is None:
        return 0
    workflows = data['items']
    running_workflows = [wf for wf in workflows if 'phase' not in wf['status'] or wf['status']['phase'] == 'Running']
    return len(running_workflows)

gvcf_dir = args.gvcf_dir if (args.gvcf_dir[-1] == "/") else (args.gvcf_dir + "/")
os.system("mkdir -p {}".format(gvcf_dir))
output_dir = args.output_dir if (args.output_dir[-1] == "/") else (args.output_dir + "/")
os.system("mkdir -p {}".format(output_dir))

# Get a list of all gvcf files to process
files = os.listdir(gvcf_dir)
files_with_paths = [gvcf_dir + file for file in files]
files_to_process = dict(zip(files, files_with_paths))
if len(files_to_process) == 0:
    sys.exit("No files to process")

# Loop over all files
file_plink_merge_list = "{}plink_merge_list.txt".format(output_dir)
for file, path in files_to_process.items():
    if "gvcf.gz" not in file:
        continue
    if "md5" in file or "tbi" in file:
        continue

    if args.sequencing_provider == 'revvity':
        result = re.search(r'^\S+\-(\d+)_\d+-WGS.+\.hard-filtered.gvcf.gz$', file)
    elif args.sequencing_provider == 'genedx':
        result = re.search(r'^(\S+).hard-filtered.gvcf.gz$', file)
    
    if result:
        sample_id = result.group(1)

        # Wait until the number of running workflows is less than max simultaneous jobs
        while get_running_workflows() >= args.simultaneous_jobs:
            time.sleep(30)

        # Create output dir for sample
        sample_output_dir = "{}{}/".format(output_dir, sample_id)
        if not os.path.exists(sample_output_dir):
            os.makedirs(sample_output_dir)

        # Create workflow args for gvcf file
        wf_arguments = {
            "output_dir": sample_output_dir,
            "sample_id": sample_id,
            "gvcf": path,
            "ref_prefix": args.ref_prefix,
            "include_homozygous_ref": args.include_homozygous_ref,
            "filter_by_qual": args.filter_by_qual,
            "filter_by_gq": args.filter_by_gq,
            "hom_gq_threshold": args.hom_gq_threshold,
            "het_gq_threshold": args.het_gq_threshold
        }
        if args.entrypoint == 'ancestry-from-gvcf':
            wf_arguments["ancestry_pop_type"] = args.ancestry_pop_type
            wf_arguments["ancestries_to_include"] = args.ancestries_to_include
            wf_arguments["std_dev_cutoff"] = args.std_dev_cutoff
            wf_arguments["scale_to_ref"] = bool(args.scale_to_ref)
        file_wf_arguments = sample_output_dir + args.entrypoint.replace('-', '_') + '.json'
        with open(file_wf_arguments, 'w', encoding='utf-8') as f:
            json.dump(wf_arguments, f)
        
        # Submit the workflow for the current file
        generate_name = sample_id.lower().replace('_', '') + "-"
        workflow = {
            "namespace": "early-check-rs-1",
            "serverDryRun": False,
            "workflow": {
                "metadata": {
                    "namespace": "early-check-rs-1",
                    "generateName": generate_name
                },
                "spec": {
                    "entrypoint": args.entrypoint,
                    "arguments": {
                        "parameters": [
                            {
                                "name": "wf_arguments",
                                "value": file_wf_arguments
                            }
                        ]
                    },
                    "workflowTemplateRef": {
                        "name": args.workflow_template
                    }
                }
            }
        }

        headers = {'Content-Type': 'application/json'}
        print(f"Starting file: {file}")
        response = requests.post(args.argo_api_url, headers=headers, data=json.dumps(workflow))

        # Write sample plink output prefix to merge list
        with open(file_plink_merge_list, 'a') as f:
            f.write("{}{}/{}\n".format(sample_output_dir, "convert_dataset_vcf_to_bfile", sample_id))
