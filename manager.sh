#!/bin/bash

save=(
    "/var/lib/docker/containers"
    "/var/lib/docker/network"
    "/var/lib/docker/volumes"
)
current_date=$(date +"%d_%m_%Y_%H_%M")
backup_folder="./backup"
server_user=""
server_ip=""
server_path=""

install_docker() {
    echo "Starting Docker installation..."
    sudo apt-get update && sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg-agent \
        software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo docker run hello-world
    echo "Docker successfully installed."
}

install_portainer() {
    echo "Starting Portainer installation..."
    docker volume create portainer_data
    docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
    echo "Portainer successfully installed."
}

install_cockpit() {
    echo "Starting Cockpit installation..."
    sudo apt update && sudo apt install -y cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit cockpit-sosreport
    sudo systemctl enable --now cockpit.socket
    if sudo systemctl is-active --quiet ufw; then sudo ufw allow 9090/tcp; fi
    echo "Cockpit is accessible at: https://$(hostname -I | awk '{print $1}'):9090"
}

install_zip_unzip() {
    echo "Installing zip and unzip..."
    sudo apt update && sudo apt install -y zip unzip
    echo "zip and unzip successfully installed."
}

backup() {
    mkdir -p $backup_folder
    output_file="$backup_folder/backup_$current_date.zip"
    json_file="$backup_folder/backup_paths.json"
    echo "{" > "$json_file"
    echo '  "backup_folders": [' >> "$json_file"
    zip -r "$output_file" "${save[@]}"
    for i in "${!save[@]}"; do
        if [ $i -eq $((${#save[@]} - 1)) ]; then
            echo "    \"${save[$i]}\"" >> "$json_file"
        else
            echo "    \"${save[$i]}\"," >> "$json_file"
        fi
    done
    echo '  ]' >> "$json_file"
    echo "}" >> "$json_file"
    zip -r "$output_file" "$json_file"
    rm -f "$json_file"
    echo "Backup completed: $output_file"
}

list_backups() {
    echo "Available backups:"
    local backups=($backup_folder/*.zip)
    if [ ${#backups[@]} -eq 0 ]; then
        echo "No backups found."
        return
    fi
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i) $(basename "$backup")"
        i=$((i + 1))
    done
    echo "all) Delete all backups"
    echo "0) Exit"
    read -p "Choose an option (e.g., 1,2,3 or all to delete all, 0 to exit): " backup_choice

    if [ "$backup_choice" == "0" ]; then
        return
    fi

    if [ "$backup_choice" == "all" ]; then
        echo "You have selected to delete all backups."
        echo "Are you sure you want to delete all backups? (y/n)"
        read -p "Confirm: " confirm_delete
        if [ "$confirm_delete" == "y" ]; then
            for backup in "${backups[@]}"; do
                rm -f "$backup"
                echo "Backup $(basename "$backup") deleted."
            done
        else
            echo "Backup deletion cancelled."
        fi
        return
    fi

    IFS=',' read -ra choices <<< "$backup_choice"
    local valid_selection=true
    local selected_backups=()

    for choice in "${choices[@]}"; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#backups[@]}" ]; then
            selected_backups+=("${backups[$((choice - 1))]}")
        else
            echo "Invalid number: $choice"
            valid_selection=false
        fi
    done

    if [ "$valid_selection" == true ]; then
        echo "The following backups will be deleted:"
        for selected_backup in "${selected_backups[@]}"; do
            echo "$(basename "$selected_backup")"
        done

        echo "Are you sure you want to delete these backups? (y/n)"
        read -p "Confirm: " confirm_delete
        if [ "$confirm_delete" == "y" ]; then
            for selected_backup in "${selected_backups[@]}"; do
                rm -f "$selected_backup"
                echo "Backup $(basename "$selected_backup") deleted."
            done
        else
            echo "Backup deletion cancelled."
        fi
    fi
}

restore() {
    while true; do
        list_backups
        read -p "Choose a backup number (0 to exit): " choice
        if [ "$choice" == "0" ]; then
            break
        fi
        local backups=($backup_folder/*.zip)
        if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
            echo "Invalid choice!"
            continue
        fi
        backup_path="${backups[$((choice - 1))]}"
        restore_base="./restore_temp"
        echo "Extracting backup..."
        mkdir -p "$restore_base"
        unzip -o "$backup_path" -d "$restore_base"
        json_file="$restore_base/backup_paths.json"
        if [ ! -f "$json_file" ]; then
            echo "Error: JSON file '$json_file' is missing!"
            continue
        fi
        backup_folders=$(jq -r '.backup_folders[]' "$json_file")
        for dir in $backup_folders; do
            target_path="$restore_base$dir"
            if [ -d "$target_path" ]; then
                echo "Copying $target_path to $dir..."
                sudo mkdir -p "$dir"
                sudo cp -r "$target_path"/* "$dir"
            fi
        done
        rm -rf "$restore_base"
        echo "Restore completed."
    done
}

transfer_backups() {
    if [ -z "$server_ip" ]; then
        read -p "Enter the server IP: " server_ip
    fi
    if [ -z "$server_user" ]; then
        read -p "Enter the username: " server_user
    fi
    if [ -z "$server_path" ]; then
        read -p "Enter the target path on the server: " server_path
    fi

    echo "Available backups:"
    local backups=($backup_folder/*.zip)
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i) $(basename "$backup")"
        i=$((i + 1))
    done
    echo "0) Exit"
    read -p "Choose the backups to transfer (separate by commas, e.g., 1,3,5, or 0 to exit): " backup_numbers
    if [ "$backup_numbers" == "0" ]; then
        return
    fi
    IFS=',' read -ra numbers <<< "$backup_numbers"
    
    echo "The following backups will be transferred:"
    for number in "${numbers[@]}"; do
        if [[ $number =~ ^[0-9]+$ ]] && [ "$number" -gt 0 ] && [ "$number" -le "${#backups[@]}" ]; then
            local selected_backup="${backups[$((number - 1))]}"
            echo "$(basename "$selected_backup")"
            scp "$selected_backup" "$server_user@$server_ip:$server_path"
        else
            echo "Invalid number: $number"
        fi
    done

    echo "Backup transfer completed."
}

copy_paths_to_server() {
    if [ -z "$server_ip" ]; then
        read -p "Enter the server IP: " server_ip
    fi
    if [ -z "$server_user" ]; then
        read -p "Enter the username: " server_user
    fi
    if [ -z "$server_path" ]; then
        read -p "Enter the target path on the server: " server_path
    fi

    ssh "$server_user@$server_ip" "mkdir -p $server_path"

    for path in "${save[@]}"; do
        if [ -d "$path" ]; then
            echo "Copying $path to $server_user@$server_ip:$server_path"
            scp -r "$path" "$server_user@$server_ip:$server_path"
            echo "Successfully copied $path."
        else
            echo "Error: $path does not exist or is not a directory."
        fi
    done

    echo "All paths have been copied to the server."
}

ufw_manager() {
    echo "What would you like to do?"
    echo "1) Add port"
    echo "2) Delete port"
    echo "3) Show status"
    echo "4) Enable UFW"
    echo "5) Disable UFW"
    echo "0) Exit"
    read -p "Choose an option: " option

    case $option in
        1)
            read -p "Enter port number: " port
            echo "Choose type:"
            echo "1) tcp"
            echo "2) udp"
            read -p "Choose an option: " type_option
            if [ "$type_option" == "1" ]; then
                type="tcp"
            elif [ "$type_option" == "2" ]; then
                type="udp"
            else
                echo "Invalid option. Please try again."
                return
            fi
            echo "Allow connection from:"
            echo "1) Anywhere"
            echo "2) 192.168.178.0/24"
            read -p "Choose an option: " connection
            if [ "$connection" == "1" ]; then
                sudo ufw allow $port/$type
                echo "Port $port/$type from Anywhere has been allowed."
            elif [ "$connection" == "2" ]; then
                sudo ufw allow from 192.168.178.0/24 to any port $port proto $type
                echo "Port $port/$type from 192.168.178.0/24 has been allowed."
            else
                echo "Invalid option. Please try again."
            fi
            ;;
        2)
            echo "Current allowed ports:"
            sudo ufw status numbered
            read -p "Enter the number of the rule to delete: " rule_number
            sudo ufw delete $rule_number
            echo "Rule number $rule_number has been deleted."
            ;;
        3)
            echo "Current active ports:"
            sudo ufw status verbose
            ;;
        4)
            echo "Enabling UFW..."
            sudo ufw enable
            echo "UFW has been enabled."
            ;;
        5)
            echo "Disabling UFW..."
            sudo ufw disable
            echo "UFW has been disabled."
            ;;
        0)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
}

while true; do
    echo "Select an option:"
    echo "1) Install Docker"
    echo "2) Install Portainer"
    echo "3) Install Cockpit"
    echo "4) Install zip/unzip"
    echo "5) Create Backup"
    echo "6) Perform Restore"
    echo "7) List Available Backups"
    echo "8) Transfer Backups to External Server"
    echo "9) Copy all paths to server"
    echo "10) UFW Manager"
    echo "0) Exit"
    read -p "Enter your choice (0-10): " choice
    case $choice in
        1) install_docker ;;
        2) install_portainer ;;
        3) install_cockpit ;;
        4) install_zip_unzip ;;
        5) backup ;;
        6) restore ;;
        7) list_backups ;;
        8) transfer_backups ;;
        9) copy_paths_to_server ;;
        10) ufw_manager ;;
        0) echo "Exiting script."; exit 0 ;;
        *) echo "Invalid choice. Please choose a number between 0 and 10." ;;
    esac
done
