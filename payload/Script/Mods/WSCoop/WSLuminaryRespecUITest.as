// Developer test for the luminary respec menus: a client started with -WSLumUITest opens the luminary panel,
// logs every node's refund verdict, takes back one allocated node through the same call right-click uses,
// then opens the reset confirmation and confirms it. Inert without the flag.
UCLASS()
class UWSLuminaryRespecUITest : UScriptWorldSubsystem
{
    private float Clock = 0;
    private int Step = 0;
    private bool bEnabled = false;
    private UProgressionUnlockWidget Refunded;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        bEnabled = !System::IsServer() && System::ParseParam(System::GetCommandLine(), "WSLumUITest");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!bEnabled || Game::GetLocalPlayer() == nullptr)
            return;
        Clock += DeltaTime;
        const float StepAt = Step == 0 ? 25.0 : 4.0;
        if (Clock < StepAt)
            return;
        Clock = 0;
        Step++;
        if (Step == 1)
            OpenPanel();
        else if (Step == 2)
            AllocateRoot();
        else if (Step == 3)
            AllocateChild();
        else if (Step == 4)
            Report("allocated through the menu");
        else if (Step == 5)
            RefundBlockedThenChild();
        else if (Step == 6)
            RefundOne();
        else if (Step == 7)
        {
            ReportAfterRefund();
            if (Root != nullptr)
            {
                const FString Verdict = Root.WSRefundBlockReason();
                Info(f"root {Root.GetName()} after its child went: verdict '{Verdict}'");
            }
        }
        else if (Step == 8)
            AllocateRoot();
        else if (Step == 9)
            Modal = WSLuminaryRespec::AskResetConfirmation(this, n"OnResetConfirmed", false);
        else if (Step == 10)
            ConfirmModal();
        else if (Step == 11)
        {
            Report("after reset");
            bEnabled = false;
        }
    }

    void Info(const FString& M)
    {
        WSCoop::Info(f"LUMUI {M}");
    }

    private UConfirmModalWidget Modal;

    TArray<UProgressionUnlockWidget> Nodes()
    {
        TArray<UProgressionUnlockWidget> Out;
        UWSLuminaryRespecSubsystem Registry = WSLuminaryRespec::Tracker();
        if (Registry == nullptr)
            return Out;
        for (UObject Obj : Registry.RegisteredPanels)
        {
            UTechnologyPanelWidget Panel = Cast<UTechnologyPanelWidget>(Obj);
            if (Panel == nullptr)
                continue;
            UPanelWidget Canvas = Cast<UPanelWidget>(Panel.GetWidgetFromName(n"CanvasPanel_Unlocks"));
            if (Canvas == nullptr)
                continue;
            for (UWidget Item : Canvas.GetAllChildren())
            {
                UProgressionUnlockWidget Node = Cast<UProgressionUnlockWidget>(Item);
                if (Node != nullptr)
                    Out.Add(Node);
            }
        }
        return Out;
    }

    void OpenPanel()
    {
        UPlayerInventoryWidget Inventory = Game::GetHUD() != nullptr ? Game::GetHUD().Widget_PlayerInventory : nullptr;
        UCommonButtonBase Button = Inventory != nullptr ? Cast<UCommonButtonBase>(Inventory.GetWidgetFromName(n"Button_TechnologyPanel")) : nullptr;
        if (Button == nullptr)
        {
            Info("no luminary button");
            return;
        }
        Button.OnButtonBaseClicked.Broadcast(Button);
        Info("opened the luminary panel");
    }

    private TArray<UProgressionUnlockWidget> Available;
    private UProgressionUnlockWidget Root;
    private UProgressionUnlockWidget Child;

    void AllocateRoot()
    {
        Available.Empty();
        for (UProgressionUnlockWidget Node : Nodes())
        {
            if (Node.CanUnlock())
                Available.Add(Node);
        }
        if (Available.Num() == 0)
        {
            Info("nothing allocatable");
            return;
        }
        Root = Available[0];
        Info(f"allocating all {Available.Num()} allocatable roots");
        for (UProgressionUnlockWidget Node : Available)
            Node.RequestUnlock();
    }

    void AllocateChild()
    {
        for (UProgressionUnlockWidget Node : Nodes())
        {
            if (Node.CanUnlock() && !Available.Contains(Node))
            {
                Child = Node;
                Info(f"allocating child {Child.GetName()}");
                Child.RequestUnlock();
                return;
            }
        }
        Info("no newly allocatable child");
    }

    void RefundBlockedThenChild()
    {
        for (UProgressionUnlockWidget Node : Nodes())
        {
            if (Node == Child || Node.WSAllocatedCount() <= 0)
                continue;
            const FString Verdict = Node.WSRefundBlockReason();
            if (Verdict.IsEmpty())
                continue;
            Root = Node;
            Info(f"blocked root {Node.GetName()}: '{Verdict}' -> right-click path should refuse it");
            Node.WSRequestRefund();
            return;
        }
        Info("no blocked root found");
    }

    void Report(const FString& Label)
    {
        int Allocated = 0;
        FString Text = "";
        for (UProgressionUnlockWidget Node : Nodes())
        {
            const int Count = Node.WSAllocatedCount();
            if (Count <= 0)
                continue;
            Allocated++;
            const FString Why = Node.WSRefundBlockReason();
            const FString Verdict = Why.IsEmpty() ? "ok" : Why;
            Text += f" [{Node.GetName()} x{Count} refund={Verdict}]";
        }
        Info(f"{Label}: {Nodes().Num()} nodes, {Allocated} allocated:{Text}");
    }

    void RefundOne()
    {
        Report("before refund");
        if (Child != nullptr && Child.WSAllocatedCount() > 0)
        {
            Refunded = Child;
            const FString Verdict = Child.WSRefundBlockReason();
            Info(f"refunding child {Child.GetName()} the way right-click does: verdict '{Verdict}'");
            Child.WSRequestRefund();
            return;
        }
        for (UProgressionUnlockWidget Node : Nodes())
        {
            if (Node.WSAllocatedCount() > 0 && Node.WSRefundBlockReason().IsEmpty())
            {
                Refunded = Node;
                Info(f"refunding {Node.GetName()} the way right-click does");
                Node.WSRequestRefund();
                return;
            }
        }
        Info("no refundable node");
    }

    void ReportAfterRefund()
    {
        if (Refunded != nullptr)
            Info(f"{Refunded.GetName()} allocated after refund: {Refunded.WSAllocatedCount()}");
        Report("after refund");
    }

    void ConfirmModal()
    {
        Info(f"confirm modal open: {(Modal != nullptr && Modal.IsVisible())}");
        if (Modal != nullptr)
            Modal.OnConfirmClicked(nullptr);
    }

    UFUNCTION()
    private void OnResetConfirmed(UCommonButtonBase Button)
    {
        Info("reset confirmed");
        TArray<UProgressionUnlockWidget> All = Nodes();
        if (All.Num() > 0)
            WSLuminaryRespec::RequestReset(UProgressionComponent::Get(Game::GetLocalPlayer()));
    }
};
