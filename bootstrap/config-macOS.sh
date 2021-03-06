#!/usr/bin/env bash

version="1.0.0"

_mainScript_() {

  [[ "$OSTYPE" != "darwin"* ]] \
    && fatal "We are not on macOS" "$LINENO"

  # Set Variables
  baseDir="$(_findBaseDir_)" && verbose "baseDir: $baseDir"
  rootDIR="$(dirname "$baseDir")" && verbose "rootDIR: $rootDIR"
  privateInstallScript="${HOME}/dotfiles-private/privateInstall.sh"
  pluginScripts="${baseDir}/plugins"
  brewfile="${rootDIR}/config/shell/Brewfile"
  gemfile="${rootDIR}/config/shell/Gemfile"

  # Config files
  configSymlinks="${baseDir}/config/symlinks.yaml"

  scriptFlags=()
    ($dryrun) && scriptFlags+=(--dryrun)
    ($quiet) && scriptFlags+=(--quiet)
    ($printLog) && scriptFlags+=(--log)
    ($verbose) && scriptFlags+=(--verbose)
    ($debug) && scriptFlags+=(--debug)
    ($strict) && scriptFlags+=(--strict)

  _commandLineTools_() {
    local x

    info "Checking for Command Line Tools..."

    if ! xcode-select --print-path &>/dev/null; then

      # Prompt user to install the XCode Command Line Tools
      xcode-select --install >/dev/null 2>&1

      # Wait until the XCode Command Line Tools are installed
      until xcode-select --print-path &>/dev/null 2>&1; do
        sleep 5
      done

      x=$(find '/Applications' -maxdepth 1 -regex '.*/Xcode[^ ]*.app' -print -quit)
      if [ -e "$x" ]; then
        sudo xcode-select -s "$x"
        sudo xcodebuild -license accept
      fi
      success 'Install XCode Command Line Tools'
    else
      success "Command Line Tools installed"
    fi
  }
  _commandLineTools_

  # Create symlinks
  if _seekConfirmation_ "Create symlinks to configuration files?"; then
    header "Creating Symlinks"
    _doSymlinks_ "${configSymlinks}"
  fi

  _homebrew_() {
    if ! _seekConfirmation_ "Configure Homebrew and Install Packages?"; then return; fi

    info "Checking for Homebrew..."
    (_checkForHomebrew_)

    # Uninstall old homebrew cask
    if brew list | grep -Fq brew-cask; then
      _execute_ -v "brew uninstall --force brew-cask" "Uninstalling old Homebrew-Cask ..."
    fi

    header "Updating Homebrew"
    _execute_ -v "caffeinate -ism brew update"
    _execute_ -vp "caffeinate -ism brew doctor"
    _execute_ -vp "caffeinate -ism brew upgrade"

    _execute_ -vp "brew analytics off" "Disable Homebrew analytics"

    if [ -f "$brewfile" ]; then
      if _seekConfirmation_ "A Brewfile is used to install packages. Would you like to edit this file to comment out unneeded lines?"; then
        notice "Please edit $brewfile and comment out lines you don't want. Exiting."
        _safeExit_
      else
        info "Installing packages (this may take a while) ..."
        _execute_ -vp "caffeinate -ism brew bundle --verbose --file=\"$brewfile\""
      fi
    else
      error "Could not find Brewfile. Unable to install homebrew packages." "$LINENO"
      verbose "Expected brewfile at '$brewfile'"
    fi

    _execute_ -vp "brew cleanup"
    _execute_ -vp "brew cask cleanup"
    _execute_ -vp "brew prune"
  }
  _homebrew_

  _checkASDF_() {
    info "Confirming we have asdf package manager installed ..."

    if [ ! -d "${HOME}/.asdf" ]; then
      _execute_ -v "git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.4.2"

      # shellcheck disable=SC2015
      [[ -s "${HOME}/.asdf/asdf.sh" ]] \
        && source "${HOME}/.asdf/asdf.sh" \
        || {
          error "Could not source 'asdf.sh'" "$LINENO"
          return 1
        }

      # shellcheck disable=SC2015
      [[ -s "${HOME}/.asdf/completions/asdf.bash" ]] \
        && source "${HOME}/.asdf/completions/asdf.bash" \
        || {
          error "Could not source '.asdf/completions/asdf.bash'" "$LINENO"
          return 1
        }
    fi
  }

  _installASDFPlugin_() {
    local name="$1"
    local url="$2"

    if ! asdf plugin-list | grep -Fq "$name"; then
      _execute_ -vp "asdf plugin-add \"$name\" \"$url\""
    fi
  }

  _installASDFLanguage_() {
    local language="$1"
    local version="$2"

    if [ -z "$version" ]; then
      version="$(asdf list-all "$language" | tail -1)"
    fi

    if ! asdf list "$language" | grep -Fq "$version"; then
      _execute_ -vp "asdf install \"$language\" \"$version\""
      _execute_ -vp "asdf global \"$language\" \"$version\""
    fi
  }

  _ruby_() {
    local RUBYVERSION="2.4.3"
    local rubyGem

    if ! _seekConfirmation_ "Install Ruby and Gems?"; then return; fi

    _checkASDF_  # Confirm we can install with ASDF

    header "Installing Ruby and Gems ..."
    _installASDFPlugin_ "ruby" "https://github.com/asdf-vm/asdf-ruby.git"
    _installASDFLanguage_ "ruby" "$RUBYVERSION"

    info "Installing gems ..."
    pushd "${HOME}" &>/dev/null

    _execute_ -v "gem update --system"
    _execute_ -v "gem install bundler"  # Ensure we have bundler installed

    numberOfCores=$(sysctl -n hw.ncpu)
    _execute_ -v "bundle config --global jobs $((numberOfCores - 1))"

    if [ -f "$gemfile" ]; then
      info "Installing ruby gems (this may take a while) ..."
      _execute_ -vp "caffeinate -ism bundle install --gemfile \"$gemfile\""
    else
      error "Could not find Gemfile. Unable to install ruby gems." "$LINENO"
      verbose "Expected to find Gemfile at '$gemfile'"
    fi

    # Ensure all these new items are in $PATH
    _execute_ -v "asdf reshim ruby"

    popd &>/dev/null
  }
  _ruby_

  _nodeJS_() {
    if ! _seekConfirmation_ "Install node.js and packages??"; then return; fi

    header "Installing node.js ..."

    _checkASDF_  # Confirm we can install with ASDF

    _installASDFPlugin_ "nodejs" "https://github.com/asdf-vm/asdf-nodejs.git"

    # Install the GPG Key
    _execute_ -v "bash ~/.asdf/plugins/nodejs/bin/import-release-team-keyring"

    _installASDFLanguage_ "nodejs"

    pushd "${HOME}" &>/dev/null
    notice "Installing npm packages ..."

    popd &>/dev/null

    # Ensure all these new items are in $PATH
    _execute_ -v "asdf reshim nodejs"
  }
  _nodeJS_

  _runPlugins_() {
    local plugin pluginName flags v d

    header "Running plugin scripts"

    if [ ! -d "$pluginScripts" ]; then
      error "Can't find plugins." "$LINENO"
      return 1
    fi

    # Run the bootstrap scripts in numerical order
    for plugin in "${pluginScripts}"/*.sh; do
      pluginName="$(basename ${plugin})"
      pluginName="$(echo $pluginName | sed -e 's/[0-9][0-9]-//g' | sed -e 's/-/ /g' | sed -e 's/\.sh//g')"
      if _seekConfirmation_ "Run '${pluginName}' plugin?"; then

        #Build flags
        [ -n "${scriptFlags[*]}" ] \
          && flags="${scriptFlags[*]}"
        [[ "$flags" =~ (--verbose|v) ]] \
          || flags="${flags} --verbose"
        ($dryrun) && {
          d=true
          dryrun=false
        }
        flags="${flags} --rootDIR $rootDIR"

        _execute_ -vsp "${plugin} ${flags}" "'${pluginName}' plugin"

        ($d) && dryrun=true
      fi
    done
  }
  _runPlugins_

  _privateRepo_() {
    if _seekConfirmation_ "Run Private install script"; then
      [ ! -f "${privateInstallScript}" ] \
        && {
          warning "Could not find private install script"
          return 1
        }
      "${privateInstallScript}" "${scriptFlags[*]}"
    fi
  }
  _privateRepo_

} # end _mainScript_

# ### CUSTOM FUNCTIONS ###########################

_doSymlinks_() {
  # Takes an input of a configuration YAML file and creates symlinks from it.
  # Note that the YAML file must group symlinks in a section named 'symlinks'
  local l                                 # link
  local d                                 # destination
  local s                                 # source
  local c="${1:?Must have a config file}" # config file
  local t                                 # temp file
  local line

  t="$(mktemp "${tmpDir}/XXXXXXXXXXXX")"

  [ ! -f "$c" ] \
    && {
      error "Can not find config file '$c'"
      return 1
    }

  # Parse & source Config File
  # shellcheck disable=2015
  (_parseYAML_ "${c}" >"${t}") \
    && { if $verbose; then
      verbose "-- Config Variables"
      _readFile_ "$t"
    fi; } \
    || fatal "Could not parse YAML config file" "$LINENO"

  _sourceFile_ "$t"

  [ "${#symlinks[@]}" -eq 0 ] \
    && {
      warning "No symlinks found in '$c'" "$LINENO"
      return 1
    }

  # For each link do the following
  for l in "${symlinks[@]}"; do
    verbose "Working on: $l"

    # Parse destination and source
    d=$(echo "$l" | cut -d':' -f1 | _trim_)
    s=$(echo "$l" | cut -d':' -f2 | _trim_)
    s=$(echo "$s" | cut -d'#' -f1 | _trim_) # remove comments if exist

    # Add the rootDIR to source if it exists
    [ -n "$rootDIR" ] \
      && s="${rootDIR}/${s}"

    # Grab the absolute path for the source
    s="$(_realpath_ "${s}")"

    # If we can't find a source file, skip it
    [ ! -e "${s}" ] \
      && {
        warning "Can't find source '${s}'" "$LINENO"
        continue
      }

    (_makeSymlink_ "${s}" "${d}") \
      || {
        warning "_makeSymlink_ failed for source: '$s'" "$LINENO"
        return 1
      }

  done
}

_checkForHomebrew_() {

  homebrewPrefix="/usr/local"

  if [ -d "$homebrewPrefix" ]; then
    if ! [ -r "$homebrewPrefix" ]; then
      sudo chown -R "$LOGNAME:admin" /usr/local
    fi
  else
    sudo mkdir "$homebrewPrefix"
    sudo chflags norestricted "$homebrewPrefix"
    sudo chown -R "$LOGNAME:admin" "$homebrewPrefix"
  fi

  if ! command -v brew &>/dev/null; then
    notice "Installing Homebrew..."
    #   Ensure that we can actually, like, compile anything.
    if [[ ! $(command -v gcc) || ! "$(command -v git)" ]]; then
      _commandLineTools_
    fi

    # Install Homebrew
    /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"

    brew analytics off
  else
    return 0
  fi
}

# Set Base Variables
# ----------------------
scriptName=$(basename "$0")

# Set Flags
quiet=false
printLog=false
logErrors=true
verbose=false
force=false
strict=false
dryrun=false
debug=false
sourceOnly=false
args=()

# Set Temp Directory
tmpDir="${TMPDIR:-/tmp/}$(basename "$0").$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${tmpDir}") || {
  die "Could not create temporary directory! Exiting." "$LINENO"
}

_sourceHelperFiles_() {
  local filesToSource
  local sourceFile

  filesToSource=(
    "${HOME}/dotfiles/scripting/helpers/baseHelpers.bash"
    "${HOME}/dotfiles/scripting/helpers/files.bash"
    "${HOME}/dotfiles/scripting/helpers/arrays.bash"
    "${HOME}/dotfiles/scripting/helpers/textProcessing.bash"
  )

  for sourceFile in "${filesToSource[@]}"; do
    [ ! -f "$sourceFile" ] \
      && {
        echo "error: Can not find sourcefile '$sourceFile'. Exiting."
        exit 1
      }

    source "$sourceFile"
  done
}
_sourceHelperFiles_

# Options and Usage
# -----------------------------------
_usage_() {
  echo -n "${scriptName} [OPTION]... [FILE]...

This script runs a series of installation scripts to configure a new computer running Mac OSX.
It relies on a number of YAML config files which contain the lists of packages to be installed.

This script also looks for plugin scripts in a user configurable directory for added customization.

 ${bold}Options:${reset}

  -n, --dryrun      Non-destructive. Makes no permanent changes.
  -q, --quiet       Quiet (no output)
  -L, --noErrorLog  Print log level error and fatal to a log (default 'true')
  -l, --log         Print log to file
  -s, --strict      Exit script with null variables.  i.e 'set -o nounset'
  -v, --verbose     Output more information. (Items echoed to 'verbose')
  -d, --debug       Runs script in BASH debug mode (set -x)
  -h, --help        Display this help and exit
      --source-only Bypasses main script functionality to allow unit tests of functions
      --version     Output version information and exit
      --force       Skip all user interaction.  Implied 'Yes' to all actions.
"
}

# Iterate over options breaking -ab into -a -b when needed and --foo=bar into
# --foo bar
optstring=h
unset options
while (($#)); do
  case $1 in
    # If option is of type -ab
    -[!-]?*)
      # Loop over each character starting with the second
      for ((i = 1; i < ${#1}; i++)); do
        c=${1:i:1}

        # Add current char to options
        options+=("-$c")

        # If option takes a required argument, and it's not the last char make
        # the rest of the string its argument
        if [[ $optstring == *"$c:"* && ${1:i+1} ]]; then
          options+=("${1:i+1}")
          break
        fi
      done
      ;;

    # If option is of type --foo=bar
    --?*=*) options+=("${1%%=*}" "${1#*=}") ;;
    # add --endopts for --
    --) options+=(--endopts) ;;
    # Otherwise, nothing special
    *) options+=("$1") ;;
  esac
  shift
done
set -- "${options[@]}"
unset options

# Print help if no arguments were passed.
# Uncomment to force arguments when invoking the script
# -------------------------------------
# [[ $# -eq 0 ]] && set -- "--help"

# Read the options and set stuff
while [[ $1 == -?* ]]; do
  case $1 in
    -h | --help)
      _usage_ >&2
      _safeExit_
      ;;
    -n | --dryrun) dryrun=true ;;
    -v | --verbose) verbose=true ;;
    -L | --noErrorLog) logErrors=false ;;
    -l | --log) printLog=true ;;
    -q | --quiet) quiet=true ;;
    -s | --strict) strict=true ;;
    -d | --debug) debug=true ;;
    --version)
      echo "$(basename $0) ${version}"
      _safeExit_
      ;;
    --source-only) sourceOnly=true ;;
    --force) force=true ;;
    --endopts)
      shift
      break
      ;;
    *) die "invalid option: '$1'." ;;
  esac
  shift
done

# Store the remaining part as arguments.
args+=("$@")

# Trap bad exits with your cleanup function
trap '_trapCleanup_ $LINENO $BASH_LINENO "$BASH_COMMAND" "${FUNCNAME[*]}" "$0" "${BASH_SOURCE[0]}"' \
  EXIT INT TERM SIGINT SIGQUIT

# Set IFS to preferred implementation
IFS=$' \n\t'

# Exit on error. Append '||true' when you run the script if you expect an error.
set -o errtrace
set -o errexit

# Force pipelines to fail on the first non-zero status code.
set -o pipefail

# Run in debug mode, if set
if ${debug}; then set -x; fi

# Exit on empty variable
if ${strict}; then set -o nounset; fi

# Run your script unless in 'source-only' mode
if ! ${sourceOnly}; then _mainScript_; fi

# Exit cleanly
if ! ${sourceOnly}; then _safeExit_; fi
