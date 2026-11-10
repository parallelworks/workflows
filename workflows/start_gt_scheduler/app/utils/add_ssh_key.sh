#!/bin/bash

# Example public key (replace this with your actual key)
PUBLIC_KEY="__PUBLIC_KEY__"
CONTROL="$(echo __PUBLIC_KEY)__"

if [[ ${PUBLIC_KEY} == "${CONTROL}" ]]; then
  echo "ERROR: Undefined public key"
  exit 1
fi

# File path
AUTH_KEYS_FILE="$HOME/.ssh/authorized_keys"

# Function to add public key if not already present
add_key() {
  grep -Fxq "$PUBLIC_KEY" "$AUTH_KEYS_FILE"
  if [ $? -ne 0 ]; then
    echo "$PUBLIC_KEY" >> "$AUTH_KEYS_FILE"
    echo "Public key added."
  else
    echo "Public key already exists."
  fi
}

add_key