allprojects {
    buildscript {
        repositories {
            // Temporary: dl.google.com/android/maven2 returns 404 from this network
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://repo.huaweicloud.com/repository/maven") }
            maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public") }
            google()
            mavenCentral()
            gradlePluginPortal()
        }
    }
    repositories {
        // Temporary: dl.google.com/android/maven2 returns 404 from this network
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://repo.huaweicloud.com/repository/maven") }
        maven { url = uri("https://mirrors.cloud.tencent.com/nexus/repository/maven-public") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
