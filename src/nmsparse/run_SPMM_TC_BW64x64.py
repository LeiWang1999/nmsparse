import os
from typing import Dict, List, Optional, Tuple
import subprocess
import json
from pathlib import Path
import argparse


current_path = Path(__file__).parent

def kernel_execution(kernel: str, sparsity_ratio) -> Tuple[str, float, bool]:
    # kernel execution process
    file_name_new = "spmm_TC_BW64x64.cu"
    build_path = os.path.join(current_path, "build")
    if not os.path.exists(build_path):
        # create
        os.mkdir(build_path)
    new_file_path = os.path.join(current_path, "build", file_name_new)
    with open(new_file_path, 'w') as f:
        f.write(kernel)
    avg_latency, success = run_gpu_kernel(file_name_new, sparsity_ratio)
    # kernel correctness verification failure
    if success == False:
        avg_latency = 10000
    return kernel, avg_latency, success

def run_gpu_kernel(file_name, sparsity_ratio):
    file_path = os.path.join(current_path, "build", file_name)
    executor_path = os.path.splitext(file_path)[0]
    compile_cmd = 'nvcc -gencode arch=compute_80,code=sm_80 -I{0}/cutlass/include -I{0}/cutlass/examples/common -I{0}/cutlass/examples/43_gemm_block_sparse -I{0}/cutlass/tools/util/include  \
    {1} -o {2}'.format(current_path, file_path, executor_path)
    output_file_name = f"output_log.txt"
    output_file_path = os.path.join(current_path, "build", output_file_name)
    subprocess.check_output(compile_cmd, shell = True, universal_newlines=True, timeout=600)
    latencys = []
    for i in range(2):
        command = '{} {} > {}'.format(executor_path, sparsity_ratio, output_file_path)
        #os.system('nvprof --unified-memory-profiling off ./{} 2> a_{}.txt'.format(Path(file_name).stem, file_name))
        #os.system(command)
        subprocess.check_output(command, shell = True, universal_newlines=True, timeout=600)

        if i == 0:
            continue
        latencys.append(get_kernel_run_time('{}'.format(output_file_path)))
    success = verify_successful(output_file_path)
    avg_latency = sum(latencys) / len(latencys)
    return avg_latency, success


def get_kernel_run_time(file_name):
    lines = []
    kernel_name = "Time="
    with open(file_name, 'r') as f:
        lines = f.readlines()
    for line in lines:
        if line.find(kernel_name) == -1:
            continue
        else:
            run_time = float(line.split()[-2])
            break
    return run_time

def verify_successful(file_name):
    with open(file_name, 'r') as f:
        content = f.read()
    if content.find("Pass") == -1:
        return False
    return True

def run_kernel(config, name, sparsity_ratio):
    template_name = os.path.join(current_path, "template", "spmm_TC_BW64x64.cu")
    f_template = open(template_name)
    template_str = f_template.read()
    for key, value in config.items():
        template_str = template_str.replace(key, str(value))
    kernel, avg_latency, success = kernel_execution(template_str, sparsity_ratio)

    M = config['M_GLOBAL_VAL']
    K = config['K_GLOBAL_VAL']
    N = config['N_GLOBAL_VAL']
    sparsity = config['SPARSITY_RATIO_VAL']
    # print(f"M:{M}, K:{K}, N:{N}, sparsity:{sparsity}, success:{success}, time:{avg_latency}")
    print(f"SpMM on TensorCore sparsity ratio={sparsity} shape={name} kernel=nmSPARSE_BW64x64 latency={avg_latency}")


def main():
    parser = argparse.ArgumentParser(description='Run kernel')
    parser.add_argument('--sparsity_ratio', type=float, default=0.9)
    parser.add_argument('--name', type=str, default='M9')
    parser.add_argument('--M', type=int, default=256)
    parser.add_argument('--K', type=int, default=1024)
    parser.add_argument('--N', type=int, default=1024)
    args = parser.parse_args()
    config = {}
    config['M_GLOBAL_VAL'] =  args.M
    config['K_GLOBAL_VAL'] =  args.K
    config['N_GLOBAL_VAL'] =  args.N
    config['SPARSITY_RATIO_VAL'] = args.sparsity_ratio
    if args.sparsity_ratio == 0.5:
        config['CHUNK_K_VAL'] = 32
    else:
        config['CHUNK_K_VAL'] = 64
    run_kernel(config, args.name, args.sparsity_ratio)

main()
