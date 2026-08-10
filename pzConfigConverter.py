#!/usr/bin/env python3
"""
Project Zomboid Configuration to Lua Converter
==============================================

Description:
This script converts a Project Zomboid single-player server configuration file 
(.cfg or .ini) into a properly formatted SandboxVars.lua file for dedicated servers.
It preserves all comments, spacing, and groupings so that the resulting Lua file 
can be easily read and edited by hand later.

Usage:
    python pz_config_converter.py <path_to_config_file> [server_name]

Arguments:
    <path_to_config_file>   The path to your single-player .cfg or .ini file.
    [server_name]           (Optional) The name of your server. Defaults to "servertest".
                            The output file will be named <server_name>_SandboxVars.lua.

Example:
    python pz_config_converter.py map_sand.cfg MySurvivorServer
"""

import sys
import os

def format_lua_value(val):
    """Determines if a value should be a boolean, number, or string in Lua."""
    val = val.strip()
    
    # Handle empty values
    if not val:
        return '""'
        
    # Handle booleans
    if val.lower() == 'true':
        return 'true'
    if val.lower() == 'false':
        return 'false'
        
    # Handle numbers (integers and floats)
    try:
        float(val)
        return val
    except ValueError:
        pass
        
    # If it's not empty, boolean, or number, it must be a string. Wrap in quotes.
    return f'"{val}"'

def convert_to_lua(filepath):
    """Parses a PZ .cfg file and converts it to a SandboxVars Lua structure while preserving comments."""
    if not os.path.isfile(filepath):
        print(f"Error: File '{filepath}' not found.", file=sys.stderr)
        sys.exit(1)

    lua_lines = ["SandboxVars = {"]
    active_category = None
    comment_buffer = []
    
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            stripped = line.strip()
            
            # Buffer empty lines to preserve spacing
            if not stripped:
                comment_buffer.append("")
                continue
                
            # Buffer and format comments
            if stripped.startswith('#'):
                # Convert python/ini style comments to lua style
                comment_buffer.append("--" + stripped[1:])
                continue
            elif stripped.startswith('--'):
                comment_buffer.append(stripped)
                continue
                
            # Handle key-value pairs
            if '=' in stripped:
                key, value = stripped.split('=', 1)
                key = key.strip()
                formatted_val = format_lua_value(value)
                
                # Check if it's a nested table value (e.g., ZombieLore.Speed)
                if '.' in key:
                    category, subkey = key.split('.', 1)
                    
                    # Handle category changes
                    if category != active_category:
                        if active_category is not None:
                            lua_lines.append("    },")
                        lua_lines.append(f"    {category} = {{")
                        active_category = category
                    
                    # Flush any buffered comments with nested indentation
                    for c in comment_buffer:
                        if c == "":
                            lua_lines.append("")
                        else:
                            lua_lines.append(f"        {c}")
                    comment_buffer.clear()
                    
                    # Append the actual property
                    lua_lines.append(f"        {subkey} = {formatted_val},")
                    
                else:
                    # It's a root level variable (e.g., Zombies)
                    if active_category is not None:
                        lua_lines.append("    },")
                        active_category = None
                        
                    # Flush any buffered comments with root indentation
                    for c in comment_buffer:
                        if c == "":
                            lua_lines.append("")
                        else:
                            lua_lines.append(f"    {c}")
                    comment_buffer.clear()
                    
                    lua_lines.append(f"    {key} = {formatted_val},")

    # Close any open category table at the end of the file
    if active_category is not None:
        lua_lines.append("    },")
        
    # Flush any trailing comments
    for c in comment_buffer:
        if c == "":
            lua_lines.append("")
        else:
            lua_lines.append(f"    {c}")
            
    lua_lines.append("}")
    
    return '\n'.join(lua_lines)

def main():
    if len(sys.argv) < 2:
        print("Usage: python pz_config_converter.py <path_to_config_file> [server_name]")
        print("Example: python pz_config_converter.py map_sand.cfg MySurvivorServer")
        sys.exit(1)

    filepath = sys.argv[1]
    server_name = sys.argv[2] if len(sys.argv) > 2 else "servertest"
    output_filename = f"{server_name}_SandboxVars.lua"
    
    print(f"--- Converting {os.path.basename(filepath)} to Lua ---")
    
    lua_content = convert_to_lua(filepath)
    
    # Write to file
    with open(output_filename, 'w', encoding='utf-8') as out_file:
        out_file.write(lua_content)
        
    print(f"Success! Created '{output_filename}'.")
    print("\nHow to use:")
    print(f"1. Place this generated file into your mounted Zomboid Server data folder:")
    print(f"   (e.g., ./zomboid_data/Server/{output_filename})")
    print("2. Restart your Docker container.")

if __name__ == "__main__":
    main()