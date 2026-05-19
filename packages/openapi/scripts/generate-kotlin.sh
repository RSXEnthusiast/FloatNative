#!/bin/bash
#
# Generate Kotlin models from Floatplane OpenAPI specification
# This script regenerates models from the centralized spec and auto-copies them to the Android project
#

set -e  # Exit on error

# Paths relative to packages/openapi/scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAPI_DIR="$(dirname "$SCRIPT_DIR")"  # packages/openapi
SPEC_FILE="$OPENAPI_DIR/floatplane-openapi-specification.json"
OVERLAY_FILE="$OPENAPI_DIR/spec-overlay.json"
ANDROID_PROJECT_DIR="$OPENAPI_DIR/../../apps/android"
# Target package location
TARGET_PACKAGE_DIR="$ANDROID_PROJECT_DIR/app/src/main/java/com/coulterpeterson/floatnative/openapi"

# Validate spec file exists
if [ ! -f "$SPEC_FILE" ]; then
    echo "❌ Error: OpenAPI spec not found at $SPEC_FILE"
    echo "💡 Run 'pnpm openapi:update-spec' to download the latest spec"
    exit 1
fi

# Use temporary directory for generation (auto-cleaned up)
TEMP_OUTPUT_DIR=$(mktemp -d -t floatplane-openapi-kotlin)
MERGED_SPEC="$TEMP_OUTPUT_DIR/spec-merged.json"

# Ensure cleanup on exit
trap "rm -rf '$TEMP_OUTPUT_DIR'" EXIT

echo "🔄 Generating Floatplane API Kotlin models..."
echo "📁 Using spec: $SPEC_FILE"
echo "📁 Using temporary staging: $TEMP_OUTPUT_DIR"

# Apply local overlay (loosened required fields, missing properties, etc.) so
# iOS and Android both pick up the same overrides.
if [ -f "$OVERLAY_FILE" ]; then
    echo "🩹 Applying spec overlay: $OVERLAY_FILE"
    python3 "$SCRIPT_DIR/apply-overlay.py" "$MERGED_SPEC"
else
    cp "$SPEC_FILE" "$MERGED_SPEC"
fi

# Generate models to temporary directory
echo "🏗️  Generating Kotlin models..."
# Using jvm-retrofit2 library with moshi serialization
# We set the package name to match our target structure
openapi-generator generate \
    -i "$MERGED_SPEC" \
    -g kotlin \
    -o "$TEMP_OUTPUT_DIR" \
    --additional-properties=library=jvm-retrofit2,serializationLibrary=moshi,packageName=com.coulterpeterson.floatnative.openapi,useCoroutines=true \
    --skip-validate-spec \
    > /dev/null 2>&1

echo "✅ Generation successful"

echo ""
echo "📦 Copying generated code to Android project..."

# Create target directory if it doesn't exist
mkdir -p "$TARGET_PACKAGE_DIR"

# Hand-written models that override the codegen output. These must be
# re-applied AFTER the generator's wipe + copy. Each entry is a path
# relative to the openapi target package dir. See the file headers for the
# rationale.
HAND_WRITTEN_OVERRIDES=(
    "models/BlogPostModelV3Channel.kt"
)

OVERRIDES_BACKUP=$(mktemp -d)
for override in "${HAND_WRITTEN_OVERRIDES[@]}"; do
    src="$TARGET_PACKAGE_DIR/$override"
    if [ -f "$src" ]; then
        mkdir -p "$OVERRIDES_BACKUP/$(dirname "$override")"
        cp "$src" "$OVERRIDES_BACKUP/$override"
    else
        echo "⚠️  Override not present pre-generation: $override"
    fi
done

# Clean old generated code
# Be careful not to delete manual extensions if they are mixed in, but ideally extensions should be in a separate directory/package
# For now, we assume this directory is owned by the generator
rm -rf "$TARGET_PACKAGE_DIR"/*

# Copy the generated source code
# The generator outputs to src/main/kotlin/com/coulterpeterson/floatnative/openapi
# We move that content to our target content
SOURCE_CODE_DIR="$TEMP_OUTPUT_DIR/src/main/kotlin/com/coulterpeterson/floatnative/openapi"

if [ -d "$SOURCE_CODE_DIR" ]; then
    cp -r "$SOURCE_CODE_DIR/" "$TARGET_PACKAGE_DIR/"
    echo "✅ Copied files to $TARGET_PACKAGE_DIR"
else
    echo "❌ Error: Generated source directory not found at $SOURCE_CODE_DIR"
    exit 1
fi

# Re-apply hand-written overrides on top of the freshly generated files.
echo ""
echo "🩹 Restoring hand-written overrides..."
for override in "${HAND_WRITTEN_OVERRIDES[@]}"; do
    backup="$OVERRIDES_BACKUP/$override"
    target="$TARGET_PACKAGE_DIR/$override"
    if [ -f "$backup" ]; then
        mkdir -p "$(dirname "$target")"
        cp "$backup" "$target"
        echo "   • $override"
    fi
done
rm -rf "$OVERRIDES_BACKUP"

# Post-processing: turn `@Query("fetchAfter") fetchAfter: Map<…,…>? = null` into
# `@QueryMap fetchAfter: Map<…,…> = emptyMap()` so Retrofit serializes each map
# entry as its own query parameter (Floatplane expects bracket-encoded keys
# like fetchAfter[0][creatorId]=…). The OpenAPI Kotlin generator emits @Query
# even for type:object params; this rewrite is what makes HomeFeedViewModel's
# manual key encoding land as bracket-form query strings in the request URL.
# See spec-overlay.json /api/v3/content/creator/list for context.
CONTENT_API="$TARGET_PACKAGE_DIR/apis/ContentV3Api.kt"
if [ -f "$CONTENT_API" ] && grep -q '@Query("fetchAfter") fetchAfter: kotlin.collections.Map' "$CONTENT_API"; then
    sed -i '' \
        -e 's|@Query("fetchAfter") fetchAfter: kotlin.collections.Map<kotlin.String, kotlin.String>? = null|@QueryMap fetchAfter: kotlin.collections.Map<kotlin.String, kotlin.String> = kotlin.collections.emptyMap()|g' \
        "$CONTENT_API"
    # Ensure the @QueryMap symbol is in scope. retrofit2.http.* import is
    # already present in the generated file, but @QueryMap specifically may not
    # be. Add it idempotently next to the existing retrofit2 imports.
    if ! grep -q 'import retrofit2.http.QueryMap' "$CONTENT_API"; then
        sed -i '' '/^import retrofit2.http.Query$/a\
import retrofit2.http.QueryMap
' "$CONTENT_API"
    fi
    echo "✅ Rewrote fetchAfter param to @QueryMap in ContentV3Api.kt"
fi

# Post-processing: parameter enums lost their `override fun toString() = value`
# block in newer openapi-generator versions. Without it Retrofit's @Query
# serializes the Kotlin enum *name* (e.g. `hlsPeriodFmp4`) instead of the wire
# value (`hls.fmp4`), and Floatplane responds 400 "outputKind ... not allowed".
# Multi-video posts surfaced this because the user opened a new post for the
# first time since the regen. Inject the toString override into every parameter
# enum that carries a `value` ctor arg.
python3 - "$TARGET_PACKAGE_DIR/apis" <<'PY'
import sys, re, pathlib
apis_dir = pathlib.Path(sys.argv[1])
pattern = re.compile(
    r"(enum class \w+\(val value: kotlin\.String\)\s*\{\n)((?:.*\n)*?)(\s*\}\n)",
    re.MULTILINE,
)
def add_toString(m):
    header, body, close = m.group(1), m.group(2), m.group(3)
    if "override fun toString" in body:
        return header + body + close
    # The last enum entry may end with "," or just whitespace; either way we
    # need to terminate it with ";" before appending the toString method.
    stripped = body.rstrip()
    if stripped.endswith(","):
        stripped = stripped[:-1]
    new_body = stripped + ";\n\n        override fun toString(): kotlin.String = value\n"
    return header + new_body + close
for kt in apis_dir.glob("*.kt"):
    src = kt.read_text()
    new = pattern.sub(add_toString, src)
    if new != src:
        kt.write_text(new)
        print(f"✅ Restored toString() on parameter enums in {kt.name}")
PY

TOTAL_FILES=$(find "$TARGET_PACKAGE_DIR" -name "*.kt" | wc -l | tr -d ' ')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Kotlin Generation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Summary:"
echo "   • Total generated files: $TOTAL_FILES"
echo "   • Location: apps/android/app/src/main/java/com/coulterpeterson/floatnative/openapi"
echo ""

