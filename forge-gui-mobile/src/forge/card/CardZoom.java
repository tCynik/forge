package forge.card;

import java.util.ArrayList;
import java.util.List;
import java.util.Map.Entry;

import com.badlogic.gdx.Gdx;
import com.badlogic.gdx.Input;
import com.badlogic.gdx.math.Interpolation;
import com.badlogic.gdx.math.Rectangle;
import com.badlogic.gdx.utils.Align;

import forge.Forge;
import forge.Graphics;
import forge.animation.ForgeAnimation;
import forge.assets.FSkinFont;
import forge.assets.FSkinImage;
import forge.deck.ArchetypeDeckGenerator;
import forge.deck.CardThemedDeckGenerator;
import forge.deck.CommanderDeckGenerator;
import forge.deck.DeckProxy;
import forge.game.GameView;
import forge.game.card.Card;
import forge.game.card.CardView;
import forge.gamemodes.planarconquest.ConquestCommander;
import forge.item.IPaperCard;
import forge.item.InventoryItem;
import forge.item.PaperCard;
import forge.localinstance.properties.ForgePreferences;
import forge.localinstance.properties.ForgePreferences.FPref;
import forge.model.FModel;
import forge.screens.match.MatchController;
import forge.toolbox.FCardPanel;
import forge.toolbox.FDialog;
import forge.toolbox.FLabel;
import forge.toolbox.FOverlay;
import forge.util.ImageUtil;
import forge.util.Utils;
import forge.util.collect.FCollectionView;

public class CardZoom extends FOverlay {
    private static final float REQ_AMOUNT = Utils.AVG_FINGER_WIDTH;

    private static final CardZoom cardZoom = new CardZoom();
    private static final ForgePreferences prefs = FModel.getPreferences();
    private static List<?> items;
    private static int currentIndex, initialIndex;
    private static CardView currentCard, prevCard, nextCard;
    private static boolean zoomMode = true;
    private static boolean oneCardView = prefs.getPrefBoolean(FPref.UI_SINGLE_CARD_ZOOM);
    private float totalZoomAmount;
    private static ActivateHandler activateHandler;
    private static String currentActivateAction;
    private static Rectangle flipIconBounds;
    private static Rectangle mutateIconBounds;
    private static FLabel specialize;
    private static boolean showAltState;
    private static boolean showBackSide = false;
    private static boolean showMerged = false;
    private static final float INACTIVE_SCALE = 0.4f; //how far the active card shrinks when fully dragged away; also the resting size of the displaced (замещаемая) card
    private static float slideOffset = 0f;
    private static SlideAnimation activeSlideAnimation;
    private static boolean dragged; //true once pan() fires for the current gesture
    private static boolean outgoingSettle; //true while the neighbor slot is the just-replaced card fleeing off-screen (no scaling), false while it's a drag candidate (scaled)
    private static float slideDistance; //cached from the last layout; the unit of travel for the whole slide/scale transition

    public static void show(Object item) {
        show(item, false);
    }

    public static void show(Object item, boolean showbackside) {
        List<Object> items0 = new ArrayList<>();
        items0.add(item);
        showBackSide = showbackside; //reverse the displayed zoomed card for the choice list
        show(items0, 0, null);
    }

    public static void show(FCollectionView<?> items0, int currentIndex0, ActivateHandler activateHandler0) {
        show((List<?>) items0, currentIndex0, activateHandler0);
    }

    public static void show(final List<?> items0, int currentIndex0, ActivateHandler activateHandler0) {
        items = items0;
        if (items == null) { return; }
        if (currentIndex0 < 0 || items.size() <= currentIndex0) { return; }
        activateHandler = activateHandler0;
        currentIndex = currentIndex0;
        initialIndex = currentIndex0;
        currentCard = getCardView(items.get(currentIndex));
        prevCard = currentIndex > 0 ? getCardView(items.get(currentIndex - 1)) : null;
        nextCard = currentIndex < items.size() - 1 ? getCardView(items.get(currentIndex + 1)) : null;
        onCardChanged();
        if (activeSlideAnimation != null) {
            activeSlideAnimation.stop();
        }
        slideOffset = 0f;
        dragged = false;
        outgoingSettle = false;
        cardZoom.show();
    }

    public static boolean isOpen() {
        return cardZoom.isVisible();
    }

    public static void hideZoom() {
        if (activateHandler != null)
            activateHandler.setSelectedIndex(currentIndex);
        cardZoom.hide();
    }

    private CardZoom() {
        specialize = add(new FLabel.ButtonBuilder().text(Forge.getLocalizer().getMessage("lblSpecialized")).font(FSkinFont.get(12)).selectable().command(e -> {
            if (currentCard != null) {
                final List<CardView> list = new ArrayList<>();
                final PaperCard pc = ImageUtil.getPaperCardFromImageKey(currentCard.getCurrentState().getTrackableImageKey());
                if (pc != null) {
                    Card cardW = Card.fromPaperCard(pc, null);
                    cardW.setState(CardStateName.SpecializeW, true);
                    list.add(cardW.getView());

                    Card cardU = Card.fromPaperCard(pc, null);
                    cardU.setState(CardStateName.SpecializeU, true);
                    list.add(cardU.getView());

                    Card cardB = Card.fromPaperCard(pc, null);
                    cardB.setState(CardStateName.SpecializeB, true);
                    list.add(cardB.getView());

                    Card cardR = Card.fromPaperCard(pc, null);
                    cardR.setState(CardStateName.SpecializeR, true);
                    list.add(cardR.getView());

                    Card cardG = Card.fromPaperCard(pc, null);
                    cardG.setState(CardStateName.SpecializeG, true);
                    list.add(cardG.getView());
                }
                if (!list.isEmpty())
                    show(list, 0, null);
            }
        }).buildAboveOverlay());
        specialize.setVisible(false);
    }

    @Override
    public void setVisible(boolean visible0) {
        if (this.isVisible() == visible0) {
            return;
        }

        super.setVisible(visible0);

        //update selected index when hidden if current index is different than initial index
        if (!visible0 && activateHandler != null && currentIndex != initialIndex) {
            activateHandler.setSelectedIndex(currentIndex);
        }
    }

    private static void incrementCard(int dir) {
        if (dir > 0) {
            if (currentIndex == items.size() - 1) {
                return;
            }
            currentIndex++;

            prevCard = currentCard;
            currentCard = nextCard;
            nextCard = currentIndex < items.size() - 1 ? getCardView(items.get(currentIndex + 1)) : null;
        }
        else {
            if (currentIndex == 0) { return; }
            currentIndex--;

            nextCard = currentCard;
            currentCard = prevCard;
            prevCard = currentIndex > 0 ? getCardView(items.get(currentIndex - 1)) : null;
        }
        onCardChanged();
        startSlideAnimation(dir);
    }

    private static void startSlideAnimation(int dir) {
        float distance = slideDistance;
        if (distance <= 0) { return; } //overlay not laid out yet

        outgoingSettle = true;
        settleTo(dir > 0 ? distance : -distance);
    }

    private static void settleTo(float offset) {
        if (activeSlideAnimation != null) {
            activeSlideAnimation.stop();
        }
        if (offset == 0) {
            slideOffset = 0;
            return;
        }
        activeSlideAnimation = new SlideAnimation(offset);
        activeSlideAnimation.start();
    }

    //commit a drag past the reveal threshold: swap card identities like incrementCard(dir),
    //but continue the settle animation from the drag's current offset instead of restarting
    //from a full off-screen distance, so the motion doesn't jump when the finger releases
    private static void commitDrag(int dir, float distance) {
        if (dir > 0) {
            currentIndex++;
            prevCard = currentCard;
            currentCard = nextCard;
            nextCard = currentIndex < items.size() - 1 ? getCardView(items.get(currentIndex + 1)) : null;
        } else {
            currentIndex--;
            nextCard = currentCard;
            currentCard = prevCard;
            prevCard = currentIndex > 0 ? getCardView(items.get(currentIndex - 1)) : null;
        }
        onCardChanged();
        outgoingSettle = true;
        settleTo(dir > 0 ? slideOffset + distance : slideOffset - distance);
    }

    private static class SlideAnimation extends ForgeAnimation {
        private static final float DURATION = 0.2f;

        private final float startOffset;
        private float elapsed;

        private SlideAnimation(float startOffset) {
            this.startOffset = startOffset;
            slideOffset = startOffset;
        }

        @Override
        protected boolean advance(float dt) {
            elapsed += dt;
            if (elapsed >= DURATION) {
                slideOffset = 0;
                return false;
            }
            slideOffset = startOffset * (1 - Interpolation.pow2Out.apply(elapsed / DURATION));
            return true;
        }

        @Override
        protected void onEnd(boolean endingAll) {
            slideOffset = 0;
            activeSlideAnimation = null;
        }
    }

    private static void onCardChanged() {
        mutateIconBounds = null;
        if (activateHandler != null) {
            currentActivateAction = activateHandler.getActivateAction(currentIndex);
        }
        if (MatchController.instance.mayFlip(currentCard)) {
            flipIconBounds = new Rectangle();
        } else {
            flipIconBounds = null;
        }
        if (currentCard != null) {
            if (!currentCard.getMergedCardsCollection().isEmpty())
                mutateIconBounds = new Rectangle();
        }
        showAltState = false;
        specialize.setVisible(
                currentCard != null && currentCard.canSpecialize() && currentCard.getCurrentState().getState() == CardStateName.Original
        );
    }

    private static CardView getCardView(Object item) {
        if (item instanceof Entry) {
            item = ((Entry<?, ?>) item).getKey();
        }
        if (item instanceof CardView cw) {
            return cw;
        }
        if (item instanceof DeckProxy deck) {
            if (item instanceof CardThemedDeckGenerator gen) {
                return CardView.getCardForUi(gen.getPaperCard());
            } else if (item instanceof CommanderDeckGenerator gen) {
                return CardView.getCardForUi(gen.getPaperCard());
            } else if (item instanceof ArchetypeDeckGenerator gen) {
                return CardView.getCardForUi(gen.getPaperCard());
            } else {
                return new CardView(-1, null, deck.getName(), null, deck.getImageKey(false));
            }

        }
        if (item instanceof IPaperCard ipc) {
            return CardView.getCardForUi(ipc);
        }
        if (item instanceof ConquestCommander cc) {
            return CardView.getCardForUi(cc.getCard());
        }
        if (item instanceof InventoryItem ii) {
            return new CardView(-1, null, ii.getDisplayName(), null, ii.getImageKey(false));
        }
        return new CardView(-1, null, item.toString());
    }

    @Override
    public boolean tap(float x, float y, int count) {
        if (mutateIconBounds != null && mutateIconBounds.contains(x, y)) {
            if (showMerged) {
                showMerged = false;
            } else {
                showMerged = true;
                show(currentCard.getMergedCardsCollection(), 0, null);
            }
            return true;
        }
        if (flipIconBounds != null && flipIconBounds.contains(x, y)) {
            if (currentCard.isFaceDown() && currentCard.getBackup() != null) {
                if (currentCard.getBackup().hasBackSide() || currentCard.getBackup().isFlipCard() || currentCard.getBackup().hasSecondaryState()) {
                    show(currentCard.getBackup());
                    return true;
                }
            }
            if (!showBackSide)
                showAltState = !showAltState;
            else
                showBackSide = !showBackSide;
            return true;
        }
        hide();
        showBackSide = false;
        showAltState = false;
        showMerged = false;
        return true;
    }

    @Override
    public boolean fling(float velocityX, float velocityY) {
        if (Math.abs(velocityX) > Math.abs(velocityY)) {
            if (dragged) {
                //already handled by pan()/panStop() as this gesture played out; avoid a
                //double navigation from a fast-but-short touch drag also exceeding the
                //fling velocity threshold
                dragged = false;
                return true;
            }
            incrementCard(velocityX > 0 ? -1 : 1);
            showBackSide = false;
            showAltState = false;
            return true;
        }
        if (velocityY > 0) {
            zoomMode = !zoomMode;
            showBackSide = false;
            showAltState = false;
            return true;
        }
        if (currentActivateAction != null && activateHandler != null) {
            hide();
            showBackSide = false;
            showAltState = false;
            activateHandler.activate(currentIndex);
            return true;
        }
        return false;
    }

    @Override
    public boolean pan(float x, float y, float deltaX, float deltaY, boolean moreVertical) {
        dragged = true;
        outgoingSettle = false; //finger back in control; neighbor is a fresh drag candidate again
        if (moreVertical || items == null) {
            return true;
        }
        //block only pushing further past the boundary, not correcting back toward center
        if (deltaX > 0 && prevCard == null && slideOffset >= 0) { return true; }
        if (deltaX < 0 && nextCard == null && slideOffset <= 0) { return true; }

        if (activeSlideAnimation != null) {
            activeSlideAnimation.stop();
        }
        slideOffset += deltaX;
        float distance = slideDistance;
        if (distance > 0) { //only one neighbor is ever drawn, so don't drag past it
            slideOffset = Math.max(-distance, Math.min(distance, slideOffset));
        }
        return true;
    }

    @Override
    public boolean panStop(float x, float y) {
        if (slideOffset == 0 || items == null) {
            return true;
        }
        float distance = slideDistance;
        float threshold = distance * 0.125f;
        if (slideOffset > threshold && prevCard != null) {
            commitDrag(-1, distance);
        } else if (slideOffset < -threshold && nextCard != null) {
            commitDrag(1, distance);
        } else {
            settleTo(0);
        }
        return true;
    }

    private void setOneCardView(boolean oneCardView0) {
        if (oneCardView == oneCardView0 || Forge.isLandscapeMode()) {
            return;
        } //don't allow changing this when in landscape mode

        oneCardView = oneCardView0;
        prefs.setPref(FPref.UI_SINGLE_CARD_ZOOM, oneCardView0);
        prefs.save();
    }

    @Override
    public boolean zoom(float x, float y, float amount) {
        totalZoomAmount += amount;

        if (totalZoomAmount >= REQ_AMOUNT) {
            setOneCardView(true);
            totalZoomAmount = 0;
        } else if (totalZoomAmount <= -REQ_AMOUNT) {
            setOneCardView(false);
            totalZoomAmount = 0;
        }
        return true;
    }

    @Override
    public boolean longPress(float x, float y) {
        setOneCardView(!oneCardView);
        return true;
    }

    @Override
    public void drawOverlay(Graphics g) {
        final GameView gameView = MatchController.instance.getGameView();

        float w = getWidth();
        float h = getHeight();
        float messageHeight = FDialog.MSG_HEIGHT;
        float AspectRatioMultiplier;
        switch (Forge.extrawide) {
            case "default":
                AspectRatioMultiplier = 3; //good for tablets with 16:10 or similar
                break;
            case "wide":
                AspectRatioMultiplier = 2.5f;
                break;
            case "extrawide":
                AspectRatioMultiplier = 2; //good for tall phones with 21:9 or similar
                break;
            default:
                AspectRatioMultiplier = 3;
                break;
        }
        float maxCardHeight = h - AspectRatioMultiplier * messageHeight; //maxheight of currently zoomed card

        float cardWidth, cardHeight, y;

        if (oneCardView && !Forge.isLandscapeMode()) {
            cardWidth = w;
            cardHeight = FCardPanel.ASPECT_RATIO * cardWidth;

            boolean rotateSplit = FModel.getPreferences().getPrefBoolean(ForgePreferences.FPref.UI_ROTATE_SPLIT_CARDS);
            if (currentCard != null && currentCard.isSplitCard() && rotateSplit) {
                // card will be rotated.  Make sure that the height does not exceed the width of the view
                if (cardHeight > Gdx.graphics.getWidth()) {
                    cardHeight = Gdx.graphics.getWidth();
                    cardWidth = cardHeight / FCardPanel.ASPECT_RATIO;
                }
            }
        } else {
            cardWidth = w * 0.5f;
            cardHeight = FCardPanel.ASPECT_RATIO * cardWidth;

            float maxSideCardHeight = maxCardHeight * 5 / 7;
            if (cardHeight > maxSideCardHeight) { //prevent card overlapping message bars
                cardHeight = maxSideCardHeight;
                cardWidth = cardHeight / FCardPanel.ASPECT_RATIO;
            }
            y = (h - cardHeight) / 2;
            if (slideOffset == 0) { //once dragging starts, these are replaced by the animated versions below
                if (prevCard != null) {
                    CardImageRenderer.drawZoom(g, prevCard, gameView, false, 0, y, cardWidth, cardHeight, getWidth(), getHeight(), false);
                }
                if (nextCard != null) {
                    CardImageRenderer.drawZoom(g, nextCard, gameView, false, w - cardWidth, y, cardWidth, cardHeight, getWidth(), getHeight(), false);
                }
            }

            cardWidth = w * 0.7f;
            cardHeight = FCardPanel.ASPECT_RATIO * cardWidth;
        }

        if (cardHeight > maxCardHeight) { //prevent card overlapping message bars
            cardHeight = maxCardHeight;
            cardWidth = cardHeight / FCardPanel.ASPECT_RATIO;
        }
        //cache for pan()/panStop(), which have no layout info of their own; a full card-width
        //made the transition feel cramped/rushed, so the whole gesture spans two card-widths
        slideDistance = cardWidth * 2f;
        float x = (w - cardWidth) / 2 + slideOffset;
        y = (h - cardHeight) / 2;
        //0 at center, 1 at fully handed off to the incoming card
        float slideProgress = slideDistance > 0 ? Math.min(1f, Math.abs(slideOffset) / slideDistance) : 0f;
        float centerScale = 1f - (1f - INACTIVE_SCALE) * slideProgress;
        float incomingScale = slideProgress; //grows from nothing at the edge to full size at center, no starting pop
        //displaced card ramps up to its constant resting scale over a small fraction of the
        //drag so it doesn't pop into existence at full size on the very first frame, then
        //holds that scale for the rest of its exit, per spec: no size change while leaving
        float displacedScale = INACTIVE_SCALE * Math.min(1f, slideProgress / 0.08f);
        //the replaced card only exists as a drag candidate; its whole exit is driven live by
        //the finger, so once a commit has happened it's already off-screen and isn't drawn
        //(the incoming card, now currentCard, takes over the center on its own)
        if (!outgoingSettle) {
            if (slideOffset > 0) {
                //incoming: was waiting just off to the left, slides in and grows to take over center
                if (prevCard != null) {
                    drawSlideNeighbor(g, prevCard, gameView, x - cardWidth, y, cardWidth, cardHeight, incomingScale);
                }
                //displaced: was resting just off to the right, gets pushed further out of view
                if (nextCard != null) {
                    drawSlideNeighbor(g, nextCard, gameView, x + cardWidth, y, cardWidth, cardHeight, displacedScale);
                }
            } else if (slideOffset < 0) {
                if (nextCard != null) {
                    drawSlideNeighbor(g, nextCard, gameView, x + cardWidth, y, cardWidth, cardHeight, incomingScale);
                }
                if (prevCard != null) {
                    drawSlideNeighbor(g, prevCard, gameView, x - cardWidth, y, cardWidth, cardHeight, displacedScale);
                }
            }
        }
        float centerDrawWidth = cardWidth * centerScale;
        float centerDrawHeight = cardHeight * centerScale;
        float centerDrawX = x + (cardWidth - centerDrawWidth) / 2;
        float centerDrawY = y + (cardHeight - centerDrawHeight) / 2;
        if (zoomMode) {
            if (currentCard != null)
                CardImageRenderer.drawZoom(g, currentCard, gameView, showBackSide? showBackSide : showAltState, centerDrawX, centerDrawY, centerDrawWidth, centerDrawHeight, getWidth(), getHeight(), true);
        } else {
            if (currentCard != null)
                CardImageRenderer.drawDetails(g, currentCard, gameView, showBackSide ? showBackSide : showAltState, centerDrawX, centerDrawY, centerDrawWidth, centerDrawHeight);
        }

        if (!showMerged) {
            if (mutateIconBounds != null) {
                float oldAlpha = g.getfloatAlphaComposite();
                try {
                    g.setAlphaComposite(0.6f);
                    drawIconBounds(g, mutateIconBounds, Forge.hdbuttons ? FSkinImage.HDLIBRARY : FSkinImage.LIBRARY, x, y, cardWidth, cardHeight);
                    g.setAlphaComposite(oldAlpha);
                } catch (Exception e) {
                    mutateIconBounds = null;
                    g.setAlphaComposite(oldAlpha);
                }
            } else if (flipIconBounds != null) {
                drawIconBounds(g, flipIconBounds, Forge.hdbuttons ? FSkinImage.HDFLIPCARD : FSkinImage.FLIPCARD, x, y, cardWidth, cardHeight);
            }
        } else if (flipIconBounds != null) {
            drawIconBounds(g, flipIconBounds, Forge.hdbuttons ? FSkinImage.HDFLIPCARD : FSkinImage.FLIPCARD, x, y, cardWidth, cardHeight);
        }

        if (currentActivateAction != null) {
            g.fillRect(FDialog.getMsgBackColor(), 0, 0, w, messageHeight);
            g.drawText(Forge.getLocalizer().getMessage("lblSwipeUpTo").replace("%s", currentActivateAction), FDialog.MSG_FONT, FDialog.getMsgForeColor(), 0, 0, w, messageHeight, false, Align.center, true);
        }
        g.fillRect(FDialog.getMsgBackColor(), 0, h - messageHeight, w, messageHeight);
        g.drawText(zoomMode ? Forge.getLocalizer().getMessage("lblSwipeDownDetailView") : Forge.getLocalizer().getMessage("lblSwipeDownPictureView"), FDialog.MSG_FONT, FDialog.getMsgForeColor(), 0, h - messageHeight, w, messageHeight, false, Align.center, true);

        if (specialize.isVisible()) {
            specialize.setBounds(w/2 - specialize.getAutoSizeBounds().width/2, h - specialize.getAutoSizeBounds().height - messageHeight, specialize.getAutoSizeBounds().width, specialize.getAutoSizeBounds().height);
        }
        interrupt(false);
    }

    private void drawSlideNeighbor(Graphics g, CardView card, GameView gameView, float x, float y, float cardWidth, float cardHeight, float scale) {
        float drawWidth = cardWidth * scale;
        float drawHeight = cardHeight * scale;
        float drawX = x + (cardWidth - drawWidth) / 2;
        float drawY = y + (cardHeight - drawHeight) / 2;
        if (zoomMode) {
            CardImageRenderer.drawZoom(g, card, gameView, false, drawX, drawY, drawWidth, drawHeight, getWidth(), getHeight(), false);
        } else {
            CardImageRenderer.drawDetails(g, card, gameView, false, drawX, drawY, drawWidth, drawHeight);
        }
    }

    private void drawIconBounds(Graphics g, Rectangle iconBounds, FSkinImage skinImage, float x, float y, float cardWidth, float cardHeight) {
        float imageWidth = cardWidth / 2;
        float imageHeight = imageWidth * skinImage.getHeight() / skinImage.getWidth();
        iconBounds.set(x + (cardWidth - imageWidth) / 2, y + (cardHeight - imageHeight) / 2, imageWidth, imageHeight);
        g.drawImage(skinImage, iconBounds.x, iconBounds.y, iconBounds.width, iconBounds.height);
    }

    @Override
    protected void doLayout(float width, float height) {
    }

    public interface ActivateHandler {
        String getActivateAction(int index);

        void setSelectedIndex(int index);

        void activate(int index);
    }

    public void interrupt(boolean resume) {
        if (MatchController.instance.hasLocalPlayers())
            return;
        if (resume && MatchController.instance.isGamePaused()) {
            MatchController.instance.resumeMatch();
            return;
        }
        if (!MatchController.instance.isGamePaused())
            MatchController.instance.pauseMatch();
    }

    @Override
    public boolean keyDown(int keyCode) {
        if (Forge.hasGamepad()) {
            if (keyCode == Input.Keys.DPAD_LEFT)
                fling(300, 0);
            else if (keyCode == Input.Keys.DPAD_RIGHT)
                fling(-300, 0);
            else if (keyCode == Input.Keys.BUTTON_B)
                hideZoom();
            else if (keyCode == Input.Keys.BUTTON_A)
                fling(0, -300f);
            else if (keyCode == Input.Keys.BUTTON_X) {
                if (mutateIconBounds != null) {
                    tap(mutateIconBounds.x, mutateIconBounds.y, 1);
                }
                if (flipIconBounds != null) {
                    tap(flipIconBounds.x, flipIconBounds.y, 1);
                }
            } else if (keyCode == Input.Keys.BUTTON_Y)
                fling(0, 300f);
            return true;
        }
        return super.keyDown(keyCode);
    }
}
