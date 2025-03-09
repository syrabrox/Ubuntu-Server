#!/bin/bash

save=(
    "/var/lib/docker/containers"
    "/var/lib/docker/network"
    "/var/lib/docker/volumes"
)
current_date=$(date +"%d_%m_%Y_%H_%M")
backup_folder="./backup"
server_user="admin"
server_ip="asa"
server_path="/Users/admin/Documents/server_backup/"

install_docker() {
    echo "Starting Docker installation..."
    sudo apt-get update && sudo apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg-agent \
        software-properties-common
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
    docker network create container_network
    echo "Portainer successfully installed."
}

install_cockpit() {
    echo "Starting Cockpit installation..."
    sudo apt update && sudo apt install -y cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit cockpit-sosreport
    sudo systemctl enable --now cockpit.socket
    if sudo systemctl is-active --quiet ufw; then sudo ufw allow 9090/tcp; fi
    echo "Cockpit is accessible at: https://$(hostname -I | awk '{print $1}'):9090"
}

install_tar() {
    echo "Installing tar..."
    sudo apt update && sudo apt install -y tar
    echo "tar successfully installed."
}

backup() {
    mkdir -p "$backup_folder"
    output_file="$backup_folder/backup_$current_date.tar.gz"
    sudo tar -czpf "$output_file" --absolute-names "${save[@]}"
    echo "Backup completed: $output_file"
}

restore() {
    echo "Available backup files:"
    local backups=($backup_folder/*.tar.gz)
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i) $(basename "$backup")"
        i=$((i + 1))
    done
    echo "0) Exit"
    
    read -p "Choose a backup file to restore (enter the number, or 0 to exit): " choice
    if [ "$choice" == "0" ]; then
        return
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "${#backups[@]}" ]; then
        backup_path="${backups[$((choice - 1))]}"
        echo "Restoring backup from: $backup_path"
        sudo tar -xzpf "$backup_path" -C /
        echo "Restore completed."
    else
        echo "Invalid choice, please try again."
    fi
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
    local backups=($backup_folder/*.tar.gz)
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

get_backups_from_server() {
    if [ -z "$server_ip" ]; then
        read -p "Enter the server IP: " server_ip
    fi
    if [ -z "$server_user" ]; then
        read -p "Enter the username: " server_user
    fi
    if [ -z "$server_path" ]; then
        read -p "Enter the path on the server where backups are stored: " server_path
    fi

    server_os=$(ssh "$server_user@$server_ip" "uname -s" 2>/dev/null)

    if [[ "$server_os" == "Linux" ]]; then
        echo "Fetching available backup files from Linux server..."
        ssh "$server_user@$server_ip" "ls -1 $server_path/*.tar.gz" > available_backups.txt
    else
        echo "Fetching available backup files from Windows server..."
        ssh "$server_user@$server_ip" "dir \"$server_path\"\\*.tar.gz /b" > available_backups.txt
    fi

    if [ ! -s available_backups.txt ]; then
        echo "No backup files found on the server."
        rm -f available_backups.txt  
        return
    fi

    echo "Available backup files on the server:"
    i=1
    while read -r backup; do
        echo "$i) $(basename "$backup")"
        i=$((i + 1))
    done < available_backups.txt
    echo "0) Exit"

    read -p "Choose a backup file to download (enter the number, or 0 to exit): " choice
    if [ "$choice" == "0" ]; then
        rm -f available_backups.txt  
        return
    fi

    selected_backup=$(sed -n "${choice}p" < available_backups.txt)
    if [ -z "$selected_backup" ]; then
        echo "Invalid choice. Please try again."
        rm -f available_backups.txt 
        return
    fi

    echo "Downloading backup from: $selected_backup"
    scp "$server_user@$server_ip:\"$server_path\\$selected_backup\"" "$backup_folder/"
    echo "Backup downloaded to $backup_folder."

    rm -f available_backups.txt
}

while true; do
    echo "Select an option:"
    echo "1) Install Docker"
    echo "2) Install Portainer"
    echo "3) Install Cockpit"
    echo "4) Install Tar"
    echo "5) Create Backup"
    echo "6) Perform Restore"
    echo "7) Upload Backups"
    echo "8) Copy all paths to server"
    echo "9) UFW Manager"
    echo "10) Download Backups"
    echo "0) Exit"
    read -p "Enter your choice (0-10): " choice
    case $choice in
        1) install_docker ;;
        2) install_portainer ;;
        3) install_cockpit ;;
        4) install_tar ;;
        5) backup ;;
        6) restore ;;
        7) transfer_backups ;;
        8) copy_paths_to_server ;;
        9) ufw_manager ;;
        10) get_backups_from_server ;;
        0) echo "Exiting script."; exit 0 ;;
        *) echo "Invalid choice. Please choose a number between 0 and 10" ;;
    esac
done
