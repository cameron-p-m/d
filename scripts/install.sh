zig build -Doptimize=ReleaseSmall

# Ensure ~/.d/bin exists
mkdir -p ~/.d/bin

# Copy d binary to ~/.d/, overwrite if it already exists
cp -f ./zig-out/bin/d ~/.d/

# Copy env script to ~/.d/bin, overwrite if it already exists
cp -f ./scripts/env.sh ~/.d/bin/

# Add sourcing of env script to ~/.zshrc if not already present
grep -qxF 'source ~/.d/bin/env.sh' ~/.zshrc || echo 'source ~/.d/bin/env.sh' >> ~/.zshrc
