package forge.assets;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

import com.badlogic.gdx.Gdx;
import com.badlogic.gdx.files.FileHandle;

import forge.localinstance.properties.ForgeConstants;
import forge.localinstance.properties.ForgePreferences;
import forge.localinstance.properties.ForgePreferences.FPref;
import forge.model.FModel;

public class FLanguage {

    //Matches exactly "xx-XX.properties" (e.g. "ru-RU.properties"), so files that merely live
    //in the same directory without being a top-level UI language - e.g. per-world Adventure
    //content bundles like "adventure-shandalar-ru-RU.properties" - aren't offered as a
    //selectable language.
    private static final Pattern LANGUAGE_FILE_PATTERN = Pattern.compile("^[a-z]{2}-[A-Z]{2}\\.properties$");

    public static void changeLanguage(final String languageName) {
        final ForgePreferences prefs = FModel.getPreferences();
        if (languageName.equals(prefs.getPref(FPref.UI_LANGUAGE))) { return; }

        //save language preference
        prefs.setPref(FPref.UI_LANGUAGE, languageName);
        prefs.save();
    }

    /**
     * Gets the languages.
     *
     * @return the languages
     */
    public static Iterable<String> getAllLanguages() {
        final List<String> allLanguages = new ArrayList<>();

        final FileHandle dir = Gdx.files.absolute(ForgeConstants.LANG_DIR);
        for (FileHandle languageFile : dir.list()) {
            String languageName = languageFile.name();
            if (!LANGUAGE_FILE_PATTERN.matcher(languageName).matches()) { continue; }
            allLanguages.add(languageName.replace(".properties", ""));
        }

        return allLanguages;
    }

}
