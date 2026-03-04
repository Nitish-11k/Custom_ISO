cd /home/nickx/.gemini/antigravity/scratch/custom_iso
# extract iso root
rm -rf extract
mkdir extract
sudo mount -o loop custom.iso extract
cp -r extract/boot/ iso_root_test
sudo umount extract
ls -la iso_root_test/boot/
ls -la iso_root_test/boot/core_custom.gz
