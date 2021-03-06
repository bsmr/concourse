module Dashboard.Dashboard exposing
    ( documentTitle
    , handleCallback
    , handleDelivery
    , init
    , subscriptions
    , update
    , view
    )

import Concourse.Cli as Cli
import Dashboard.Details as Details
import Dashboard.Filter as Filter
import Dashboard.Footer as Footer
import Dashboard.Group as Group
import Dashboard.Group.Models exposing (Group)
import Dashboard.Models as Models
    exposing
        ( DashboardError(..)
        , Dropdown(..)
        , Model
        , SubState
        )
import Dashboard.SearchBar as SearchBar
import Dashboard.Styles as Styles
import Dashboard.Text as Text
import EffectTransformer exposing (ET)
import Html exposing (Html)
import Html.Attributes
    exposing
        ( attribute
        , class
        , download
        , href
        , id
        , src
        , style
        )
import Html.Events
    exposing
        ( onMouseEnter
        , onMouseLeave
        )
import Http
import List.Extra
import Login.Login as Login
import Message.Callback exposing (Callback(..))
import Message.Effects exposing (Effect(..))
import Message.Message as Message exposing (Hoverable(..), Message(..))
import Message.Subscription
    exposing
        ( Delivery(..)
        , Interval(..)
        , Subscription(..)
        )
import Message.TopLevelMessage exposing (TopLevelMessage(..))
import Monocle.Compose exposing (optionalWithLens, optionalWithOptional)
import Monocle.Lens
import Monocle.Optional
import MonocleHelpers exposing (bind, modifyWithEffect)
import RemoteData
import Routes
import ScreenSize exposing (ScreenSize(..))
import UserState exposing (UserState)
import Views.Styles
import Views.TopBar as TopBar


type alias Flags =
    { turbulencePath : String
    , searchType : Routes.SearchType
    , pipelineRunningKeyframes : String
    , clusterName : String
    }


substateOptional : Monocle.Optional.Optional Model SubState
substateOptional =
    Monocle.Optional.Optional (.state >> RemoteData.toMaybe) (\s m -> { m | state = RemoteData.Success s })


init : Flags -> ( Model, List Effect )
init flags =
    ( { state = RemoteData.NotAsked
      , turbulencePath = flags.turbulencePath
      , pipelineRunningKeyframes = flags.pipelineRunningKeyframes
      , groups = []
      , version = ""
      , hovered = Nothing
      , userState = UserState.UserStateUnknown
      , hideFooter = False
      , hideFooterCounter = 0
      , showHelp = False
      , highDensity = flags.searchType == Routes.HighDensity
      , query = Routes.extractQuery flags.searchType
      , isUserMenuExpanded = False
      , dropdown = Hidden
      , screenSize = Desktop
      , clusterName = flags.clusterName
      }
    , [ FetchData
      , PinTeamNames Message.Effects.stickyHeaderConfig
      , GetScreenSize
      ]
    )


handleCallback : Callback -> ET Model
handleCallback msg ( model, effects ) =
    case msg of
        APIDataFetched (Err _) ->
            ( { model
                | state =
                    RemoteData.Failure (Turbulence model.turbulencePath)
              }
            , effects
            )

        APIDataFetched (Ok ( now, apiData )) ->
            let
                groups =
                    Group.groups apiData

                noPipelines =
                    List.isEmpty <| List.concatMap .pipelines groups

                newModel =
                    case model.state of
                        RemoteData.Success substate ->
                            { model
                                | state =
                                    RemoteData.Success (Models.tick now substate)
                            }

                        _ ->
                            { model
                                | state =
                                    RemoteData.Success
                                        { now = now
                                        , dragState = Models.NotDragging
                                        , dropState = Models.NotDropping
                                        }
                            }

                userState =
                    case apiData.user of
                        Just u ->
                            UserState.UserStateLoggedIn u

                        Nothing ->
                            UserState.UserStateLoggedOut
            in
            if model.highDensity && noPipelines then
                ( { newModel
                    | groups = groups
                    , highDensity = False
                    , version = apiData.version
                    , userState = userState
                  }
                , effects
                    ++ [ ModifyUrl <|
                            Routes.toString <|
                                Routes.dashboardRoute False
                       ]
                )

            else
                ( { newModel
                    | groups = groups
                    , version = apiData.version
                    , userState = userState
                  }
                , effects
                )

        LoggedOut (Ok ()) ->
            ( { model | userState = UserState.UserStateLoggedOut }
            , effects
                ++ [ NavigateTo <|
                        Routes.toString <|
                            Routes.dashboardRoute <|
                                model.highDensity
                   , FetchData
                   ]
            )

        ScreenResized viewport ->
            let
                newSize =
                    ScreenSize.fromWindowSize
                        viewport.viewport.width
            in
            ( { model | screenSize = newSize }, effects )

        PipelineToggled _ (Ok ()) ->
            ( model, effects ++ [ FetchData ] )

        PipelineToggled _ (Err err) ->
            case err of
                Http.BadStatus { status } ->
                    ( model
                    , if status.code == 401 then
                        effects ++ [ RedirectToLogin ]

                      else
                        effects
                    )

                _ ->
                    ( model, effects )

        _ ->
            ( model, effects )


handleDelivery : Delivery -> ET Model
handleDelivery delivery =
    SearchBar.handleDelivery delivery
        >> Footer.handleDelivery delivery
        >> handleDeliveryBody delivery


handleDeliveryBody : Delivery -> ET Model
handleDeliveryBody delivery ( model, effects ) =
    case delivery of
        ClockTicked OneSecond time ->
            ( { model | state = RemoteData.map (Models.tick time) model.state }
            , effects
            )

        ClockTicked FiveSeconds _ ->
            ( model, effects ++ [ FetchData ] )

        _ ->
            ( model, effects )


update : Message -> ET Model
update msg =
    SearchBar.update msg >> updateBody msg


updateBody : Message -> ET Model
updateBody msg ( model, effects ) =
    case msg of
        DragStart teamName index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dragState = Models.Dragging teamName index }) model.state }
            in
            ( newModel, effects )

        DragOver _ index ->
            let
                newModel =
                    { model | state = RemoteData.map (\s -> { s | dropState = Models.Dropping index }) model.state }
            in
            ( newModel, effects )

        TooltipHd pipelineName teamName ->
            ( model, effects ++ [ ShowTooltipHd ( pipelineName, teamName ) ] )

        Tooltip pipelineName teamName ->
            ( model, effects ++ [ ShowTooltip ( pipelineName, teamName ) ] )

        DragEnd ->
            let
                updatePipelines :
                    ( Group.PipelineIndex, Group.PipelineIndex )
                    -> Group
                    -> ( Group, List Effect )
                updatePipelines ( dragIndex, dropIndex ) group =
                    let
                        newGroup =
                            Group.shiftPipelines dragIndex dropIndex group
                    in
                    ( newGroup
                    , [ SendOrderPipelinesRequest newGroup.teamName newGroup.pipelines ]
                    )

                dragDropOptional : Monocle.Optional.Optional Model ( Models.DragState, Models.DropState )
                dragDropOptional =
                    substateOptional
                        |> optionalWithLens
                            (Monocle.Lens.tuple
                                Details.dragStateLens
                                Details.dropStateLens
                            )

                dragDropIndexOptional : Monocle.Optional.Optional Model ( Group.PipelineIndex, Group.PipelineIndex )
                dragDropIndexOptional =
                    dragDropOptional
                        |> optionalWithOptional
                            (Monocle.Optional.zip
                                Group.dragIndexOptional
                                Group.dropIndexOptional
                            )

                groupsLens : Monocle.Lens.Lens Model (List Group)
                groupsLens =
                    Monocle.Lens.Lens .groups (\b a -> { a | groups = b })

                groupOptional : Monocle.Optional.Optional Model Group
                groupOptional =
                    -- the point of this optional is to find the group whose
                    -- name matches the name name in the dragstate
                    (substateOptional
                        |> optionalWithLens Details.dragStateLens
                        |> optionalWithOptional Group.teamNameOptional
                    )
                        |> bind
                            (\teamName ->
                                groupsLens
                                    |> Monocle.Optional.fromLens
                                    |> optionalWithOptional
                                        (Group.findGroupOptional teamName)
                            )

                bigOptional : Monocle.Optional.Optional Model ( ( Group.PipelineIndex, Group.PipelineIndex ), Group )
                bigOptional =
                    Monocle.Optional.tuple
                        dragDropIndexOptional
                        groupOptional

                ( newModel, unAccumulatedEffects ) =
                    model
                        |> modifyWithEffect bigOptional
                            (\( t, g ) ->
                                let
                                    ( newG, newMsg ) =
                                        updatePipelines t g
                                in
                                ( ( t, newG ), newMsg )
                            )
                        |> Tuple.mapFirst (dragDropOptional.set ( Models.NotDragging, Models.NotDropping ))
            in
            ( newModel, effects ++ unAccumulatedEffects )

        Hover hovered ->
            ( { model | hovered = hovered }, effects )

        LogOut ->
            ( { model | state = RemoteData.NotAsked }, effects )

        TogglePipelinePaused pipelineId isPaused ->
            let
                newGroups =
                    model.groups
                        |> List.Extra.updateIf
                            (.teamName >> (==) pipelineId.teamName)
                            (\g ->
                                let
                                    newPipelines =
                                        g.pipelines
                                            |> List.Extra.updateIf
                                                (.name >> (==) pipelineId.pipelineName)
                                                (\p -> { p | isToggleLoading = True })
                                in
                                { g | pipelines = newPipelines }
                            )
            in
            ( { model | groups = newGroups }
            , effects
                ++ [ SendTogglePipelineRequest pipelineId isPaused ]
            )

        _ ->
            ( model, effects )


subscriptions : List Subscription
subscriptions =
    [ OnClockTick OneSecond
    , OnClockTick FiveSeconds
    , OnMouse
    , OnKeyDown
    , OnKeyUp
    , OnWindowResize
    ]


documentTitle : String
documentTitle =
    "Dashboard"


view : UserState -> Model -> Html Message
view userState model =
    Html.div
        (id "page-including-top-bar" :: Views.Styles.pageIncludingTopBar)
        [ Html.div
            (id "top-bar-app" :: Views.Styles.topBar False)
          <|
            [ Html.div
                [ style "display" "flex"
                , style "align-items" "center"
                ]
                [ TopBar.concourseLogo, clusterName model ]
            ]
                ++ (let
                        isDropDownHidden =
                            model.dropdown == Hidden

                        isMobile =
                            model.screenSize == ScreenSize.Mobile
                    in
                    if
                        not model.highDensity
                            && isMobile
                            && (not isDropDownHidden || model.query /= "")
                    then
                        [ SearchBar.view model ]

                    else if not model.highDensity then
                        [ SearchBar.view model
                        , Login.view userState model False
                        ]

                    else
                        [ Login.view userState model False ]
                   )
        , Html.div
            (id "page-below-top-bar" :: (Views.Styles.pageBelowTopBar <| Routes.Dashboard (Routes.Normal Nothing)))
            (dashboardView model)
        ]


clusterName : Model -> Html Message
clusterName model =
    Html.div
        Styles.clusterName
        [ Html.text model.clusterName ]


dashboardView : Model -> List (Html Message)
dashboardView model =
    case model.state of
        RemoteData.NotAsked ->
            [ Html.text "" ]

        RemoteData.Loading ->
            [ Html.text "" ]

        RemoteData.Failure (Turbulence path) ->
            [ turbulenceView path ]

        RemoteData.Success substate ->
            [ Html.div
                (class (.pageBodyClass Message.Effects.stickyHeaderConfig)
                    :: Styles.content model.highDensity
                )
              <|
                welcomeCard model
                    :: pipelinesView
                        { groups = model.groups
                        , substate = substate
                        , query = model.query
                        , hovered = model.hovered
                        , pipelineRunningKeyframes =
                            model.pipelineRunningKeyframes
                        , userState = model.userState
                        , highDensity = model.highDensity
                        }
            , Footer.view model
            ]


welcomeCard :
    { a
        | hovered : Maybe Hoverable
        , groups : List Group
        , userState : UserState.UserState
    }
    -> Html Message
welcomeCard { hovered, groups, userState } =
    let
        noPipelines =
            List.isEmpty (groups |> List.concatMap .pipelines)

        cliIcon : Maybe Hoverable -> Cli.Cli -> Html Message
        cliIcon hoverable cli =
            Html.a
                ([ href <| Cli.downloadUrl cli
                 , attribute "aria-label" <| Cli.label cli
                 , id <| "top-cli-" ++ Cli.id cli
                 , onMouseEnter <| Hover <| Just <| Message.WelcomeCardCliIcon cli
                 , onMouseLeave <| Hover Nothing
                 , download ""
                 ]
                    ++ Styles.topCliIcon
                        { hovered =
                            hoverable
                                == (Just <| Message.WelcomeCardCliIcon cli)
                        , cli = cli
                        }
                )
                []
    in
    if noPipelines then
        Html.div
            (id "welcome-card" :: Styles.welcomeCard)
            [ Html.div
                Styles.welcomeCardTitle
                [ Html.text Text.welcome ]
            , Html.div
                Styles.welcomeCardBody
              <|
                [ Html.div
                    [ style "display" "flex"
                    , style "align-items" "center"
                    ]
                  <|
                    [ Html.div
                        [ style "margin-right" "10px" ]
                        [ Html.text Text.cliInstructions ]
                    ]
                        ++ List.map (cliIcon hovered) Cli.clis
                , Html.div
                    []
                    [ Html.text Text.setPipelineInstructions ]
                ]
                    ++ loginInstruction userState
            , Html.pre
                Styles.asciiArt
                [ Html.text Text.asciiArt ]
            ]

    else
        Html.text ""


loginInstruction : UserState.UserState -> List (Html Message)
loginInstruction userState =
    case userState of
        UserState.UserStateLoggedIn _ ->
            []

        _ ->
            [ Html.div
                [ id "login-instruction"
                , style "line-height" "42px"
                ]
                [ Html.text "login "
                , Html.a
                    [ href "/login"
                    , style "text-decoration" "underline"
                    ]
                    [ Html.text "here" ]
                ]
            ]


noResultsView : String -> Html Message
noResultsView query =
    let
        boldedQuery =
            Html.span [ class "monospace-bold" ] [ Html.text query ]
    in
    Html.div
        (class "no-results" :: Styles.noResults)
        [ Html.text "No results for "
        , boldedQuery
        , Html.text " matched your search."
        ]


turbulenceView : String -> Html Message
turbulenceView path =
    Html.div
        [ class "error-message" ]
        [ Html.div [ class "message" ]
            [ Html.img [ src path, class "seatbelt" ] []
            , Html.p [] [ Html.text "experiencing turbulence" ]
            , Html.p [ class "explanation" ] []
            ]
        ]


pipelinesView :
    { groups : List Group
    , substate : Models.SubState
    , hovered : Maybe Message.Hoverable
    , pipelineRunningKeyframes : String
    , query : String
    , userState : UserState.UserState
    , highDensity : Bool
    }
    -> List (Html Message)
pipelinesView { groups, substate, hovered, pipelineRunningKeyframes, query, userState, highDensity } =
    let
        filteredGroups =
            groups |> Filter.filterGroups query |> List.sortWith Group.ordering

        groupViews =
            if highDensity then
                filteredGroups
                    |> List.concatMap (Group.hdView pipelineRunningKeyframes)

            else
                filteredGroups
                    |> List.map
                        (Group.view
                            { dragState = substate.dragState
                            , dropState = substate.dropState
                            , now = substate.now
                            , hovered = hovered
                            , pipelineRunningKeyframes = pipelineRunningKeyframes
                            , userState = userState
                            }
                        )
    in
    if List.isEmpty groupViews && not (String.isEmpty query) then
        [ noResultsView query ]

    else
        groupViews
