import requests
import csv
import argparse
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description="Check Azure resource move support")
    parser.add_argument("--resources", type=str, default="Azureresources.csv",
                        help="Input CSV with your Azure resources (default: Azureresources.csv)")
    args = parser.parse_args()

    move_csv = "moveSupported.csv"
    results_csv = "results.csv"
    uri = "https://raw.githubusercontent.com/tfitzmac/resource-capabilities/master/move-support-resources.csv"

    # Download the move support CSV
    print("Downloading move support data...")
    response = requests.get(uri)
    response.raise_for_status()
    with open(move_csv, "w", encoding="utf-8") as f:
        f.write(response.text)

    # Load both CSVs
    move_supported = []
    with open(move_csv, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            move_supported.append(row)

    az_resources = []
    with open(args.resources, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            az_resources.append(row)

    # Write header
    with open(results_csv, 'w', encoding='utf-8', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Resource Name", "Resource Type", "Move Subscription"])

    # Process matches
    print("Processing resources...")
    with open(results_csv, 'a', encoding='utf-8', newline='') as f:
        writer = csv.writer(f)
        
        for resource in az_resources:
            res_name = resource.get("name", "")
            res_type = resource.get("Resource Type", "")
            
            for support in move_supported:
                support_resource = support.get("Resource", "").strip().lower()
                move_sub = support.get("Move Subscription", "")
                
                if support_resource and res_type.lower().find(support_resource) != -1:
                    print(f"{res_name}, {res_type}, {move_sub}")
                    writer.writerow([res_name, res_type, move_sub])

    print(f"\nDone! Results saved to {results_csv}")

if __name__ == "__main__":
    main()