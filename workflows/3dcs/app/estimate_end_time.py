from datetime import datetime, timedelta
import re
import sys

def parse_log_file(file_path):
    # Dictionary to store timestamps for each thread
    thread_times = {}
    
    # Regular expression to parse the log lines
    pattern = r'dcsMsg: progress on mthreadIndex #(\d+), run# (\d+) of (\d+); Time: (\d{2}/\d{2}/\d{4})  at (\d{2}:\d{2}:\d{2})'
    
    try:
        with open(file_path, 'r') as file:
            for line in file:
                match = re.match(pattern, line.strip())
                if match:
                    thread_id = int(match.group(1))
                    run_num = int(match.group(2))
                    total_runs = int(match.group(3))
                    date_str = match.group(4)
                    time_str = match.group(5)
                    
                    # Parse timestamp
                    timestamp = datetime.strptime(f"{date_str} {time_str}", "%m/%d/%Y %H:%M:%S")
                    
                    if thread_id not in thread_times:
                        thread_times[thread_id] = []
                    thread_times[thread_id].append((run_num, timestamp))
        
        return thread_times, total_runs
    except FileNotFoundError:
        print(f"File {file_path} not found")
        return None, None
    except Exception as e:
        print(f"Error processing {file_path}: {str(e)}")
        return None, None

def calculate_average_time_per_iteration(thread_times, total_runs):
    iteration_times = []
    
    # Calculate time differences for each thread
    for thread_id, times in thread_times.items():
        # Sort by run number
        times.sort(key=lambda x: x[0])
        
        # Calculate time differences between consecutive runs
        for i in range(1, len(times)):
            run_diff = times[i][0] - times[i-1][0]
            time_diff = (times[i][1] - times[i-1][1]).total_seconds()
            if run_diff > 0:
                time_per_iteration = time_diff / run_diff
                iteration_times.append(time_per_iteration)
    
    # Calculate average time per iteration
    if iteration_times:
        avg_time_per_iteration = sum(iteration_times) / len(iteration_times)
        
        # Estimate completion time
        latest_timestamp = max(max(times, key=lambda x: x[1])[1] for times in thread_times.values())
        remaining_iterations = total_runs - max(max(t[0] for t in times) for times in thread_times.values())
        remaining_time = remaining_iterations * avg_time_per_iteration
        estimated_end_time = latest_timestamp + timedelta(seconds=remaining_time)
        
        return avg_time_per_iteration, estimated_end_time
    return None, None

def main(file_paths):
    end_times = []
    
    # Process each file
    for file_path in file_paths:
        print(f"\nProcessing file: {file_path}")
        thread_times, total_runs = parse_log_file(file_path)
        
        if thread_times is None or total_runs is None:
            print(f"Skipping {file_path} due to errors")
            continue
            
        if not thread_times:
            print(f"No valid data found in {file_path}")
            continue
            
        avg_time, end_time = calculate_average_time_per_iteration(thread_times, total_runs)
        
        if avg_time is None:
            print(f"Insufficient data to calculate average time for {file_path}")
            continue
            
        print(f"Average time per iteration: {avg_time:.2f} seconds")
        print(f"Estimated end time: {end_time.strftime('%m/%d/%Y at %H:%M:%S')}")
        end_times.append(end_time)
    
    # Determine and print the maximum end time
    if end_times:
        max_end_time = max(end_times)
        print(f"\nSimulation end time (maximum across all files): {max_end_time.strftime('%m/%d/%Y at %H:%M:%S')}")
    else:
        print("\nNo valid data to determine simulation end time")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Please provide a comma-separated list of file paths as an argument")
        sys.exit(1)
    
    # Split comma-separated file paths and strip whitespace
    file_paths = [path.strip() for path in sys.argv[1].split(',')]
    main(file_paths)