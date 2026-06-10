#!/usr/bin/env bash
#
# Build and install GNAT Studio from source on macOS (Apple Silicon / arm64)
# Tested on macOS 26.2 with Xcode CLT, Homebrew, Alire 2.1.0
#
# Prerequisites (installed automatically by this script):
#   - Xcode Command Line Tools  (xcode-select --install)
#   - Homebrew                  (https://brew.sh)
#   - Alire >= 2.1              (https://alire.ada.dev)
#   - uv                        (https://docs.astral.sh/uv/)
#
# Usage:
#   ./build-macos.sh                       # install to ~/gnatstudio
#   ./build-macos.sh /opt/gnatstudio       # install to custom prefix
#
set -euo pipefail

PREFIX="${1:-$HOME/gnatstudio}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SDK="$(xcrun --show-sdk-path)"
NCPU="$(sysctl -n hw.ncpu)"

###############################################################################
# 1. Install Homebrew dependencies
###############################################################################
echo "==> Installing Homebrew dependencies..."
brew install --quiet \
  gtk+3 \
  pygobject3 \
  pycairo \
  fontconfig \
  python@3.13 \
  gcc \
  gmp \
  pkg-config \
  adwaita-icon-theme

###############################################################################
# 2. Set up Alire toolchain
###############################################################################
echo "==> Setting up Alire toolchain..."
alr toolchain --select gnat_native
alr toolchain --select gprbuild

###############################################################################
# 3. Create alire.toml if it doesn't exist
###############################################################################
if [ ! -f alire.toml ]; then
  echo "==> Creating alire.toml..."
  cat > alire.toml << 'TOML'
name = "gnatstudio"
description = "GNAT Studio IDE"
version = "0.0.0"
licenses = "GPL-3.0-or-later"
authors = ["AdaCore"]

[[depends-on]]
gtkada = "*"
xmlada = "*"
gnatcoll = "*"
gnatcoll_projects = "*"
gnatcoll_iconv = "*"
libadalang = "*"
libadalang_tools = "*"
ada_language_server = "*"
gnatcoll_sqlite = "*"
gnatcoll_xref = "*"
vss_text = "*"
vss_extra = "*"
TOML
fi

###############################################################################
# 4. Fetch Alire dependencies
###############################################################################
echo "==> Fetching Alire dependencies..."
export C_INCLUDE_PATH="$SDK/usr/include"
export LIBRARY_PATH="$SDK/usr/lib:/opt/homebrew/lib"
alr update

###############################################################################
# 5. Create Python venv
###############################################################################
echo "==> Setting up Python venv..."
if [ ! -d .venv ]; then
  uv venv --python python3.13 --system-site-packages .venv
fi
uv pip install --python .venv/bin/python setuptools

###############################################################################
# 6. Resolve Alire build directories
###############################################################################
echo "==> Resolving Alire build paths..."

find_alire_dir() {
  find ~/.local/share/alire/builds/"$1"* -maxdepth 1 -type d 2>/dev/null | head -1
}

GTKADA_DIR="$(find_alire_dir gtkada_26)"
GNATCOLL_DIR="$(find_alire_dir gnatcoll_26.0.0_cc)"
GNATCOLL_GMP_DIR="$(find_alire_dir gnatcoll_gmp_26)"
GNATCOLL_ICONV_DIR="$(find_alire_dir gnatcoll_iconv_26)"
LIBGPR_DIR="$(find_alire_dir libgpr_26)"
LIBGPR2_DIR="$(find_alire_dir libgpr2_26)"
TP_DIR="$(find_alire_dir templates_parser_26)"

for d in GTKADA_DIR GNATCOLL_DIR GNATCOLL_GMP_DIR LIBGPR_DIR LIBGPR2_DIR TP_DIR; do
  if [ -z "${!d}" ]; then
    echo "ERROR: could not find Alire build dir for $d"
    exit 1
  fi
done

# These are the extra GPR_PROJECT_PATH entries GNAT Studio needs beyond
# what Alire provides (Alire puts subdirs on the path, but GS imports
# the top-level gnatcoll.gpr and gnatcoll_python.gpr by bare name).
GNATCOLL_ROOT="$(find "$GNATCOLL_DIR" -name "gnatcoll.gpr" -exec dirname {} \; 2>/dev/null | head -1)"
GNATCOLL_PYTHON3="$(find "$GNATCOLL_GMP_DIR" -path "*/python3/gnatcoll_python.gpr" -exec dirname {} \; 2>/dev/null | head -1)"

###############################################################################
# 7. Generate gtkada_shared.gpr (bypass broken configure on macOS 26)
#
# GtkAda's configure fails on macOS 26 because GNAT's bundled GCC cannot
# find macOS frameworks (Cocoa, CoreFoundation) or SDK headers. Instead of
# fighting configure, we generate the output file directly from pkg-config.
###############################################################################
echo "==> Generating gtkada_shared.gpr..."

GTK_CFLAGS_RAW="$(pkg-config --cflags gtk+-3.0)"
GTK_LIBS_RAW="$(pkg-config --libs gtk+-3.0)"
FC_LIBDIR="$(pkg-config --variable=libdir fontconfig)"

# Convert space-separated flags into GPR string array format: "-flag1", "-flag2"
gpr_array() {
  echo "$1" | tr ' ' '\n' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd',' - | sed 's/,/, /g'
}

GTK_CFLAGS_GPR="$(gpr_array "$GTK_CFLAGS_RAW")"
GTK_LIBS_GPR="$(gpr_array "$GTK_LIBS_RAW"), \"-L$FC_LIBDIR\", \"-lfontconfig\""

cat > "$GTKADA_DIR/gtkada_shared.gpr" << GTKEOF
with "gtk";

project GtkAda_Shared is
   type Build_Type is ("Debug", "Production");
   Build : Build_Type := external ("BUILD", "Production");

   type Yes_No is ("yes", "no");
   Need_Objective_C : Yes_No := "yes";

   for Source_Files use ();

   type Library_Kinds is ("relocatable", "static", "static-pic");
   Library_Kind : Library_Kinds := external ("LIBRARY_TYPE", "static");

   type So_Ext_Type is (".so", ".sl", ".dll", ".dylib");
   So_Ext      : So_Ext_Type := ".dylib";

   Version     := "26.0.0";
   Gtk_Include := Gtk.Gtk_Default_Include & ($GTK_CFLAGS_GPR);
   Gtk_Libs    := Gtk.Gtk_Default_Libs & ("-F$SDK/System/Library/Frameworks", $GTK_LIBS_GPR);

   Adaflags    := External_As_List ("ADAFLAGS", " ");
   Cflags      := External_As_List ("CFLAGS", " ");
   Cppflags    := External_As_List ("CPPFLAGS", " ");
   Ldflags     := External_As_List ("LDFLAGS", " ");
   Objcflags   := External_As_List ("OBJCFLAGS", " ");

   package Naming is
      for Body_Suffix ("Objective-C") use ".m";
   end Naming;

   package Compiler is
      for Driver ("Objective-C") use "clang";
      for Leading_Required_Switches ("Objective-C") use ("-c");
      for PIC_Option ("Objective-C") use ("-fPIC");
      for PIC_Option ("C") use ("-fPIC");

      case Build is
         when "Debug" =>
             for Switches ("Ada") use ("-gnatQ", "-gnatwae", "-gnatayM200", "-g", "-O0");
             for Switches ("C") use ("-g", "-O0", "-Wformat", "-Werror=format-security");
         when "Production" =>
             for Switches ("Ada") use ("-gnatQ", "-O2", "-gnatn", "-gnatwa", "-gnatyM200");
             for Switches ("C") use ("-O2", "-Wformat", "-Werror=format-security");
      end case;

      for Switches ("C") use Compiler'Switches ("C") & Gtk_Include;
      for Switches ("Objective-C") use Compiler'Switches ("Objective-C") & Gtk_Include;
      for Switches ("Ada") use Compiler'Switches ("Ada") & Adaflags;
      for Switches ("C") use Compiler'Switches ("C") & Cflags & Cppflags;
      for Switches ("Objective-C") use Compiler'Switches ("Objective-C") & Objcflags & Cppflags;
   end Compiler;

   package Builder is
      for Switches ("Ada") use ("-m");
      case Build is
         when "Debug" =>
            for Global_Configuration_Pragmas use GtkAda_Shared'Project_Dir & "src/gnat_debug.adc";
         when "Production" =>
            for Global_Configuration_Pragmas use GtkAda_Shared'Project_Dir & "src/gnat.adc";
      end case;
   end Builder;

   package Binder is
      case Build is
         when "Debug" =>
             for Default_Switches ("Ada") use ("-E");
         when "Production" =>
             null;
      end case;
   end Binder;

   package Linker is
      for Leading_Switches ("Ada") use Ldflags;
   end Linker;

   package IDE is
      for VCS_Kind use "auto";
   end IDE;

   package Documentation is
      for Documentation_Dir use "html";
   end Documentation;
end GtkAda_Shared;
GTKEOF

###############################################################################
# 8. Generate GtkAda Ada body from template
###############################################################################
echo "==> Generating gtkada-intl.adb from template..."
GTKADA_SRC="$GTKADA_DIR/src"
if [ -f "$GTKADA_SRC/gtkada-intl.gpb" ] && [ ! -f "$GTKADA_SRC/gtkada-intl.adb" ]; then
  alr exec -- gnatprep "$GTKADA_SRC/gtkada-intl.gpb" "$GTKADA_SRC/gtkada-intl.adb" \
    -DHAVE_GETTEXT=True -DGETTEXT_INTL=True
fi

###############################################################################
# 9. Create tp_xmlada.gpr for templates_parser
###############################################################################
echo "==> Setting up templates_parser config..."
if [ -n "$TP_DIR" ] && [ -f "$TP_DIR/config/tp_xmlada_installed.gpr" ]; then
  cp -n "$TP_DIR/config/tp_xmlada_installed.gpr" "$TP_DIR/config/tp_xmlada.gpr" 2>/dev/null || true
fi

###############################################################################
# 10. Patch dependency GPR files
#
# GNAT Studio passes -XBUILD=Production -XOS=osx globally to gprbuild.
# Several Alire-managed dependencies use incompatible typed values for
# these externals:
#
#   - gnatcoll: BUILD expects "DEBUG"/"PROD", not "Debug"/"Production"
#   - libgpr/libgpr2: OS/Target expects "Windows_NT"/"UNIX", not "osx"
#     (and their Naming case statements don't handle "osx", causing
#      wrong source file selection — e.g. Windows semaphore impl on macOS)
#   - templates_parser: BUILD expects "Debug"/"Release", not "Production"
#
# These patches add the missing values so the typed constraints pass.
###############################################################################
echo "==> Patching dependency GPR files for macOS compatibility..."

# --- gnatcoll: add "Debug"/"Production" to all ("DEBUG","PROD") types ---
find ~/.local/share/alire/builds/gnatcoll* -name "*.gpr" 2>/dev/null | while read f; do
  if grep -q 'type Build_Type is ("DEBUG", "PROD")' "$f" 2>/dev/null; then
    sed -i '' 's/type Build_Type is ("DEBUG", "PROD")/type Build_Type is ("DEBUG", "PROD", "Debug", "Production")/' "$f"
  fi
done

# --- libgpr (gpr.gpr): add "osx" to Target_type, Naming case, and Build_Type ---
if [ -n "$LIBGPR_DIR" ]; then
  GPR_FILE="$LIBGPR_DIR/gpr/gpr.gpr"
  sed -i '' 's/type Target_type is ("Windows_NT", "UNIX")/type Target_type is ("Windows_NT", "UNIX", "osx")/' "$GPR_FILE" 2>/dev/null || true
  sed -i '' 's/type Build_Type is ("debug", "production", "coverage", "profiling")/type Build_Type is ("debug", "production", "coverage", "profiling", "Debug", "Production")/' "$GPR_FILE" 2>/dev/null || true
  sed -i '' 's/when "UNIX" =>$/when "UNIX" | "osx" =>/' "$GPR_FILE" 2>/dev/null || true
fi

# --- libgpr2: add "osx" to Target_type, Naming case, and Build_Type ---
if [ -n "$LIBGPR2_DIR" ]; then
  sed -i '' 's/type Target_type is ("Windows_NT", "UNIX")/type Target_type is ("Windows_NT", "UNIX", "osx")/' "$LIBGPR2_DIR/gpr2_shared.gpr" 2>/dev/null || true
  sed -i '' 's/type Build_Type is ("debug", "release", "release_checks", "gnatcov")/type Build_Type is ("debug", "release", "release_checks", "gnatcov", "Debug", "Production")/' "$LIBGPR2_DIR/gpr2_shared.gpr" 2>/dev/null || true
  sed -i '' 's/when "UNIX" =>$/when "UNIX" | "osx" =>/' "$LIBGPR2_DIR/gpr2.gpr" 2>/dev/null || true
fi

# --- templates_parser (tp_shared.gpr): add "Production" ---
if [ -n "$TP_DIR" ]; then
  sed -i '' 's/type Build_Type is ("Debug", "Release")/type Build_Type is ("Debug", "Release", "Production")/' "$TP_DIR/tp_shared.gpr" 2>/dev/null || true
fi

###############################################################################
# 11. Patch GNAT Studio source for ALS 26.0.0 compatibility
#
# GNAT Studio master references a .hidden field on LSP.Messages.Location
# that was added after the ALS 26.0.0 release. Remove these references
# so the code compiles against the Alire-provided ALS.
###############################################################################
echo "==> Patching GNAT Studio source for ALS 26.0.0 compatibility..."
REFS_FILE="$SCRIPT_DIR/lsp_client/src/gps-lsp_client-references.adb"
if grep -q 'Element\.hidden\.Is_Set' "$REFS_FILE" 2>/dev/null; then
  sed -i '' 's/Has_Hidden := (for some Element of Result =>.*/Has_Hidden := False;/' "$REFS_FILE"
  sed -i '' '/if Loc\.hidden\.Is_Set/,/end if;/{
    /if Loc\.hidden\.Is_Set/,/Category := Data\.Titles\.First_Element;/{
      /Category := Data\.Titles\.First_Element;/!d
    }
  }' "$REFS_FILE"
  sed -i '' 's/not Loc\.hidden\.Is_Set$/True/' "$REFS_FILE"
  sed -i '' '/or else not Loc\.hidden\.Value/d' "$REFS_FILE"
fi

###############################################################################
# 12. Run configure
###############################################################################
echo "==> Running configure (prefix=$PREFIX)..."

PYCONFIG="$(/opt/homebrew/bin/python3.13-config --prefix 2>/dev/null || python3.13-config --prefix)"
PYLIB="$PYCONFIG/lib"
PYINC="$(/opt/homebrew/bin/python3.13-config --includes 2>/dev/null || python3.13-config --includes)"
PYINC="${PYINC%% *}"   # first -I flag only
PYINC="${PYINC#-I}"    # strip -I prefix

export PATH="$SCRIPT_DIR/.venv/bin:$PATH"
export GPR_PROJECT_PATH="$GNATCOLL_ROOT:$GNATCOLL_PYTHON3:${GPR_PROJECT_PATH:-}"

alr exec -- env \
  CC=gcc-15 \
  LIBRARY_PATH="$SDK/usr/lib:/opt/homebrew/lib" \
  PYTHON_LIBS="-L$PYLIB/python3.13/config-3.13-darwin -lpython3.13" \
  ./configure --prefix="$PREFIX"

###############################################################################
# 13. Build (static linking to avoid runtime dylib hunt)
###############################################################################
echo "==> Building GNAT Studio (static, Production)..."

export LIBRARY_PATH="$SDK/usr/lib:/opt/homebrew/lib"
export C_INCLUDE_PATH="$SDK/usr/include"
export GNATCOLL_BUILD_MODE=PROD
export GNATCOLL_PYTHON_CFLAGS="-I$PYINC"
export GNATCOLL_PYTHON_LIBS="-L$PYLIB/python3.13/config-3.13-darwin -lpython3.13 -ldl -F$SDK/System/Library/Frameworks -framework CoreFoundation"
export LDFLAGS="-F$SDK/System/Library/Frameworks"

mkdir -p kernel/generated
(cd kernel/src && "$SCRIPT_DIR/.venv/bin/python3" hooks.py)

# Build main binary — static linking so only system/Homebrew dylibs are needed
alr exec -- gprbuild -j"$NCPU" -m -p -ws \
  -XBUILD=Production -XOS=osx \
  -XLIBRARY_TYPE=static -XXMLADA_BUILD=static \
  -XBUILD_MODE=prod \
  -Pgnatstudio/gps \
  -largs $(pkg-config gmodule-2.0 --libs)

# Build CLI tools (gnatdoc, gnatstudio_cli)
alr exec -- gprbuild -j"$NCPU" -m -p -ws \
  -XBUILD=Production -XOS=osx \
  -XLIBRARY_TYPE=static -XXMLADA_BUILD=static \
  -XBUILD_MODE=prod \
  -Pcli/cli

###############################################################################
# 14. Install
###############################################################################
echo "==> Installing to $PREFIX..."
make install PYTHON="$SCRIPT_DIR/.venv/bin/python3"

###############################################################################
# 14b. Build and install the Ada Language Server
#
# GNAT Studio spawns "ada_language_server" (which also serves GPR files via
# --language-gpr) from PATH for navigation, completion and hover. It is not
# built by the gps/cli projects, so build its driver from the Alire-provided
# sources and install it next to the other binaries. It is static apart from
# Homebrew gmp, so a plain copy is self-contained.
###############################################################################
echo "==> Building Ada Language Server..."
ALS_GPR="$(find ~/.local/share/alire/builds/ada_language_server_* -path '*/gnat/lsp_server.gpr' 2>/dev/null | head -1)"
if [ -n "$ALS_GPR" ]; then
  alr exec -- env CC=gcc-15 \
    C_INCLUDE_PATH="$SDK/usr/include" \
    LIBRARY_PATH="$SDK/usr/lib:/opt/homebrew/lib" \
    gprbuild -j"$NCPU" -p -m -P "$ALS_GPR"
  ALS_EXE="$(find ~/.local/share/alire/builds/ada_language_server_* -path '*/.obj/server/ada_language_server' -type f 2>/dev/null | head -1)"
  if [ -n "$ALS_EXE" ]; then
    cp "$ALS_EXE" "$PREFIX/bin/ada_language_server"
    echo "    installed ada_language_server -> $PREFIX/bin"
  fi
else
  echo "WARNING: ada_language_server sources not found in Alire cache; skipping ALS build"
fi

###############################################################################
# 15. Bundle GNAT runtime dylibs alongside the binary
#
# Even with static Ada libraries, the GNAT runtime (libgnat, libgnarl) and
# GCC support lib (libgcc_s) are still dynamically linked. Copy them into
# the bin/ directory and add an @executable_path rpath so the binary finds
# them without needing DYLD_LIBRARY_PATH.
###############################################################################
echo "==> Bundling GNAT runtime libraries..."
GNAT_ADALIB="$(find ~/.local/share/alire/toolchains/gnat_native_* -path '*/adalib' -type d 2>/dev/null | head -1)"
GNAT_LIB="$(find ~/.local/share/alire/toolchains/gnat_native_* -maxdepth 1 -name lib -type d 2>/dev/null | head -1)"

for lib in libgnarl-15.dylib libgnat-15.dylib; do
  cp "$GNAT_ADALIB/$lib" "$PREFIX/bin/"
done
cp "$GNAT_LIB/libgcc_s.1.1.dylib" "$PREFIX/bin/"

for bin in gnatstudio gnatdoc3 gnatstudio_cli; do
  if [ -f "$PREFIX/bin/$bin" ]; then
    install_name_tool -add_rpath @executable_path "$PREFIX/bin/$bin" 2>/dev/null || true
  fi
done

###############################################################################
# 16. Create wrapper script for Python environment
#
# GNAT Studio embeds Python (via gnatcoll_python). The embedded interpreter
# needs PYTHONHOME to find the standard library (encodings, etc.) and
# PYTHONPATH to find site-packages (PyGObject for GTK integration).
###############################################################################
echo "==> Creating launcher wrapper..."
PYHOME="/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13"

mv "$PREFIX/bin/gnatstudio" "$PREFIX/bin/gnatstudio-bin"
cat > "$PREFIX/bin/gnatstudio" << WRAPPER
#!/usr/bin/env bash
PYHOME="/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13"
export PYTHONHOME="\$PYHOME"
export PYTHONPATH="\$HOME/gnatstudio/pythonlibs:\$PYHOME/lib/python3.13:\$PYHOME/lib/python3.13/lib-dynload:/opt/homebrew/lib/python3.13/site-packages"
GNAT_TC="\$(ls -d "\$HOME"/.local/share/alire/toolchains/gnat_native_*/bin 2>/dev/null | sort -V | tail -1)"
GPR_TC="\$(ls -d "\$HOME"/.local/share/alire/toolchains/gprbuild_*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="\$HOME/.alire/bin:\$GNAT_TC:\$GPR_TC:/usr/local/bin:/opt/homebrew/bin:\$HOME/gnatstudio/bin:\$PATH"
SDK="\$(xcrun --show-sdk-path 2>/dev/null)"
[ -n "\$SDK" ] && export LIBRARY_PATH="\$SDK/usr/lib:/opt/homebrew/lib\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
exec "\$(dirname "\$0")/gnatstudio-bin" "\$@"
WRAPPER
chmod +x "$PREFIX/bin/gnatstudio"

# Configure GTK theme (Adwaita renders correctly on macOS Quartz backend)
mkdir -p /opt/homebrew/etc/gtk-3.0
cat > /opt/homebrew/etc/gtk-3.0/settings.ini << 'GTKINI'
[Settings]
gtk-theme-name = Adwaita
gtk-icon-theme-name = Adwaita
GTKINI

###############################################################################
# 17. Create macOS .app bundle in /Applications
###############################################################################
echo "==> Creating /Applications/GNAT Studio.app..."
APP="/Applications/GNAT Studio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$SCRIPT_DIR/osx_bundle/Resources/"*.icns "$RESOURCES/"
cp "$SCRIPT_DIR/osx_bundle/Resources/"*.png "$RESOURCES/" 2>/dev/null || true

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array><string>gpr</string></array>
			<key>CFBundleTypeIconFile</key>
			<string>gpr.icns</string>
			<key>CFBundleTypeName</key>
			<string>GNAT Project file</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
		</dict>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array><string>ads</string></array>
			<key>CFBundleTypeIconFile</key>
			<string>ads.icns</string>
			<key>CFBundleTypeName</key>
			<string>Ada Specification</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
		</dict>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array><string>adb</string></array>
			<key>CFBundleTypeIconFile</key>
			<string>adb.icns</string>
			<key>CFBundleTypeName</key>
			<string>Ada Body</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
		</dict>
		<dict>
			<key>CFBundleTypeExtensions</key>
			<array><string>ada</string></array>
			<key>CFBundleTypeIconFile</key>
			<string>ada.icns</string>
			<key>CFBundleTypeName</key>
			<string>Ada File</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
		</dict>
	</array>
	<key>CFBundleExecutable</key>
	<string>gnatstudio</string>
	<key>CFBundleIconFile</key>
	<string>gps.icns</string>
	<key>CFBundleIdentifier</key>
	<string>com.adacore.gnatstudio</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>GNAT Studio</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>26.0.0</string>
	<key>CFBundleSignature</key>
	<string>ADAC</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSArchitecturePriority</key>
	<array>
		<string>arm64</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2001-2025 AdaCore</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

cat > "$MACOS/gnatstudio" << APPLAUNCHER
#!/usr/bin/env bash
PYHOME="/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13"
export PYTHONHOME="\$PYHOME"
export PYTHONPATH="\$HOME/gnatstudio/pythonlibs:\$PYHOME/lib/python3.13:\$PYHOME/lib/python3.13/lib-dynload:/opt/homebrew/lib/python3.13/site-packages"
GNAT_TC="\$(ls -d "\$HOME"/.local/share/alire/toolchains/gnat_native_*/bin 2>/dev/null | sort -V | tail -1)"
GPR_TC="\$(ls -d "\$HOME"/.local/share/alire/toolchains/gprbuild_*/bin 2>/dev/null | sort -V | tail -1)"
export PATH="\$HOME/.alire/bin:\$GNAT_TC:\$GPR_TC:/usr/local/bin:/opt/homebrew/bin:$PREFIX/bin:\$PATH"
SDK="\$(xcrun --show-sdk-path 2>/dev/null)"
[ -n "\$SDK" ] && export LIBRARY_PATH="\$SDK/usr/lib:/opt/homebrew/lib\${LIBRARY_PATH:+:\$LIBRARY_PATH}"
exec "$PREFIX/bin/gnatstudio-bin" "\$@"
APPLAUNCHER
chmod +x "$MACOS/gnatstudio"

###############################################################################
# Done
###############################################################################
echo ""
echo "============================================================"
echo "  GNAT Studio installed to: $PREFIX"
echo "  App bundle: /Applications/GNAT Studio.app"
echo ""
echo "  Launch from Spotlight, Launchpad, or:"
echo "    open '/Applications/GNAT Studio.app'"
echo ""
echo "  Or add to your shell profile for CLI use:"
echo "    export PATH=\"$PREFIX/bin:\$PATH\""
echo "============================================================"
echo ""
echo "  Runtime dependencies (via Homebrew, must stay installed):"
echo "    gtk+3, python@3.13, glib, pango, cairo, harfbuzz,"
echo "    gdk-pixbuf, atk, fontconfig, gmp, gettext,"
echo "    adwaita-icon-theme, pygobject3"
echo "============================================================"
