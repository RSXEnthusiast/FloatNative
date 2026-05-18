package com.coulterpeterson.floatnative.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.coulterpeterson.floatnative.api.FloatplaneApi
import com.coulterpeterson.floatnative.ui.screens.MainScreen
import com.coulterpeterson.floatnative.ui.screens.auth.LoginScreen
import com.coulterpeterson.floatnative.utils.DebugLogManager

@Composable
fun AppNavigation(startDestination: String = Screen.Login.route) {
    val navController = rememberNavController()

    // Observe the access-token state flow to detect when AuthInterceptor has
    // exhausted its refresh path and called tokenManager.clearAll(). This is
    // intentionally narrow:
    //   * tokenManager.clearAll() is only called from AuthInterceptor's refresh
    //     branches and the explicit logout path — not on transient network
    //     errors, decode failures, or companion-API failures.
    //   * We require a non-null → null transition. The initial null at app
    //     start is the cold-launch case, handled by startDestination upstream.
    val authToken by FloatplaneApi.tokenManager.authStateFlow.collectAsState()
    var sawAuthenticated by remember {
        mutableStateOf(!FloatplaneApi.tokenManager.accessToken.isNullOrEmpty())
    }
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route

    LaunchedEffect(authToken) {
        if (!authToken.isNullOrEmpty()) {
            sawAuthenticated = true
        } else if (sawAuthenticated && currentRoute != Screen.Login.route) {
            // We were authenticated, now we're not, and we're not already on
            // the login screen — kick the user back out.
            DebugLogManager.auth(
                "Auth expired and refresh failed; routing to login"
            )
            navController.navigate(Screen.Login.route) {
                popUpTo(0) // clear entire back stack so back-press doesn't return
                launchSingleTop = true
            }
            sawAuthenticated = false
        }
    }

    NavHost(navController = navController, startDestination = startDestination) {

        composable(Screen.Login.route) {
            LoginScreen(
                onLoginSuccess = {
                    navController.navigate(Screen.Home.route) {
                        popUpTo(Screen.Login.route) { inclusive = true }
                    }
                }
            )
        }

        composable(Screen.Home.route) {
            MainScreen(
                onPlayVideo = { videoId ->
                    navController.navigate("video/$videoId")
                },
                onNavigateToSettings = {
                    navController.navigate(Screen.Settings.route)
                }
            )
        }

        composable(
            route = "video/{postId}",
            arguments = listOf(androidx.navigation.navArgument("postId") { type = androidx.navigation.NavType.StringType })
        ) { backStackEntry ->
            val postId = backStackEntry.arguments?.getString("postId") ?: return@composable
            com.coulterpeterson.floatnative.ui.screens.VideoPlayerScreen(
                postId = postId,
                onClose = { navController.popBackStack() }
            )
        }

        composable(Screen.Settings.route) {
            com.coulterpeterson.floatnative.ui.screens.SettingsScreen(
                onBack = { navController.popBackStack() },
                onLogoutSuccess = {
                     navController.navigate(Screen.Login.route) {
                         popUpTo(Screen.Home.route) { inclusive = true }
                         // Also clear backstack completely to prevent back-press return
                         popUpTo(0)
                     }
                },
                onOpenDebugLog = {
                    navController.navigate(Screen.DebugLog.route)
                }
            )
        }

        composable(Screen.DebugLog.route) {
            com.coulterpeterson.floatnative.ui.screens.DebugLogScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}
