#!/bin/bash

# Find all files ending in .yaml recursively and rename them
find . -type f -name "*.yaml" | while read -r file; do
    # Remove .yaml from the end and append .yaml
    newfile="${file%.yaml}.yaml"
    
    echo "Renaming: '$file' -> '$newfile'"
    mv "$file" "$newfile"
done

echo "Done!"