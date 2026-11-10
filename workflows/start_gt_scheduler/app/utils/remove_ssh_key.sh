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

# Function to remove public key if present
remove_key() {
  if grep -Fxq "$PUBLIC_KEY" "$AUTH_KEYS_FILE"; then
    grep -Fxv "$PUBLIC_KEY" "$AUTH_KEYS_FILE" > "${AUTH_KEYS_FILE}.tmp" && mv "${AUTH_KEYS_FILE}.tmp" "$AUTH_KEYS_FILE"
    echo "Public key removed."
  else
    echo "Public key not found."
  fi
}

remove_key

# Example usage
# Uncomment one of the following lines to add or remove the key
# add_key
# remove_key
