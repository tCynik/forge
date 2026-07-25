package forge.adventure.data;

import com.badlogic.gdx.utils.Array;
import forge.adventure.util.Config;

/**
 * Data class that will be used to read Json configuration files
 * SettingData
 * contains data for a Shop on the map
 */
public class ShopData {

    public String name;
    public String locName;        //References a localized string for the shop name.
    public String description;
    public String locDescription; //References a localized string for the shop description.
    public int restockPrice;
    public String spriteAtlas;
    public String sprite;
    public boolean unlimited;
    public Array<RewardData> rewards;
    public String overlaySprite = "";

    public String getName() {
        return Config.instance().getMessage(locName, name);
    }

    public String getDescription() {
        return Config.instance().getMessage(locDescription, description);
    }


}
